--
-- PostgreSQL database dump
--

-- Dumped from database version 10.5 (Ubuntu 10.5-0ubuntu0.18.04)
-- Dumped by pg_dump version 10.5 (Ubuntu 10.5-0ubuntu0.18.04)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: plpgsql; Type: EXTENSION; Schema: -; Owner: 
--

CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plpgsql; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL procedural language';


--
-- Name: tsq_state; Type: TYPE; Schema: public; Owner: vagrant
--

CREATE TYPE public.tsq_state AS (
	search_query text,
	parentheses_stack integer,
	skip_for integer,
	current_token text,
	current_index integer,
	current_char text,
	previous_char text,
	tokens text[]
);


ALTER TYPE public.tsq_state OWNER TO vagrant;

--
-- Name: array_nremove(anyarray, anyelement, integer); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.array_nremove(anyarray, anyelement, integer) RETURNS anyarray
    LANGUAGE sql IMMUTABLE
    AS $_$
    WITH replaced_positions AS (
        SELECT UNNEST(
            CASE
            WHEN $2 IS NULL THEN
                '{}'::int[]
            WHEN $3 > 0 THEN
                (array_positions($1, $2))[1:$3]
            WHEN $3 < 0 THEN
                (array_positions($1, $2))[
                    (cardinality(array_positions($1, $2)) + $3 + 1):
                ]
            ELSE
                '{}'::int[]
            END
        ) AS position
    )
    SELECT COALESCE((
        SELECT array_agg(value)
        FROM unnest($1) WITH ORDINALITY AS t(value, index)
        WHERE index NOT IN (SELECT position FROM replaced_positions)
    ), $1[1:0]);
$_$;


ALTER FUNCTION public.array_nremove(anyarray, anyelement, integer) OWNER TO vagrant;

--
-- Name: poses_search_vector_update(); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.poses_search_vector_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                NEW.search_vector = ((setweight(to_tsvector('pg_catalog.english', coalesce(NEW.name, '')), 'A') || setweight(to_tsvector('pg_catalog.english', coalesce(NEW.sanskrit_unaccented, '')), 'C')) || setweight(to_tsvector('pg_catalog.english', coalesce(NEW.altnames, '')), 'B')) || setweight(to_tsvector('pg_catalog.english', coalesce(NEW.description, '')), 'D');
                RETURN NEW;
            END
            $$;


ALTER FUNCTION public.poses_search_vector_update() OWNER TO vagrant;

--
-- Name: tsq_append_current_token(public.tsq_state); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.tsq_append_current_token(state public.tsq_state) RETURNS public.tsq_state
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    IF state.current_token != '' THEN
        state.tokens := array_append(state.tokens, state.current_token);
        state.current_token := '';
    END IF;
    RETURN state;
END;
$$;


ALTER FUNCTION public.tsq_append_current_token(state public.tsq_state) OWNER TO vagrant;

--
-- Name: tsq_parse(text); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.tsq_parse(search_query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT tsq_parse(get_current_ts_config(), search_query);
$$;


ALTER FUNCTION public.tsq_parse(search_query text) OWNER TO vagrant;

--
-- Name: tsq_parse(regconfig, text); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.tsq_parse(config regconfig, search_query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT tsq_process_tokens(config, tsq_tokenize(search_query));
$$;


ALTER FUNCTION public.tsq_parse(config regconfig, search_query text) OWNER TO vagrant;

--
-- Name: tsq_parse(text, text); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.tsq_parse(config text, search_query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT tsq_parse(config::regconfig, search_query);
$$;


ALTER FUNCTION public.tsq_parse(config text, search_query text) OWNER TO vagrant;

--
-- Name: tsq_process_tokens(text[]); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.tsq_process_tokens(tokens text[]) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT tsq_process_tokens(get_current_ts_config(), tokens);
$$;


ALTER FUNCTION public.tsq_process_tokens(tokens text[]) OWNER TO vagrant;

--
-- Name: tsq_process_tokens(regconfig, text[]); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.tsq_process_tokens(config regconfig, tokens text[]) RETURNS tsquery
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    result_query text;
    previous_value text;
    value text;
BEGIN
    result_query := '';
    FOREACH value IN ARRAY tokens LOOP
        IF value = '"' THEN
            CONTINUE;
        END IF;

        IF left(value, 1) = '"' AND right(value, 1) = '"' THEN
            value := phraseto_tsquery(config, value);
        ELSIF value NOT IN ('(', ' | ', ')', '-') THEN
            value := quote_literal(value) || ':*';
        END IF;

        IF previous_value = '-' THEN
            IF value = '(' THEN
                value := '!' || value;
            ELSE
                value := '!(' || value || ')';
            END IF;
        END IF;

        SELECT
            CASE
                WHEN result_query = '' THEN value
                WHEN (
                    previous_value IN ('!(', '(', ' | ') OR
                    value IN (')', ' | ')
                ) THEN result_query || value
                ELSE result_query || ' & ' || value
            END
        INTO result_query;
        previous_value := value;
    END LOOP;

    RETURN to_tsquery(config, result_query);
END;
$$;


ALTER FUNCTION public.tsq_process_tokens(config regconfig, tokens text[]) OWNER TO vagrant;

--
-- Name: tsq_tokenize(text); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.tsq_tokenize(search_query text) RETURNS text[]
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    state tsq_state;
BEGIN
    SELECT
        search_query::text AS search_query,
        0::int AS parentheses_stack,
        0 AS skip_for,
        ''::text AS current_token,
        0 AS current_index,
        ''::text AS current_char,
        ''::text AS previous_char,
        '{}'::text[] AS tokens
    INTO state;

    state.search_query := lower(trim(
        regexp_replace(search_query, '""+', '""', 'g')
    ));

    FOR state.current_index IN (
        SELECT generate_series(1, length(state.search_query))
    ) LOOP
        state.current_char := substring(
            search_query FROM state.current_index FOR 1
        );

        IF state.skip_for > 0 THEN
            state.skip_for := state.skip_for - 1;
            CONTINUE;
        END IF;

        state := tsq_tokenize_character(state);
        state.previous_char := state.current_char;
    END LOOP;
    state := tsq_append_current_token(state);

    state.tokens := array_nremove(state.tokens, '(', -state.parentheses_stack);

    RETURN state.tokens;
END;
$$;


ALTER FUNCTION public.tsq_tokenize(search_query text) OWNER TO vagrant;

--
-- Name: tsq_tokenize_character(public.tsq_state); Type: FUNCTION; Schema: public; Owner: vagrant
--

CREATE FUNCTION public.tsq_tokenize_character(state public.tsq_state) RETURNS public.tsq_state
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    IF state.current_char = '(' THEN
        state.tokens := array_append(state.tokens, '(');
        state.parentheses_stack := state.parentheses_stack + 1;
        state := tsq_append_current_token(state);
    ELSIF state.current_char = ')' THEN
        IF (state.parentheses_stack > 0 AND state.current_token != '') THEN
            state := tsq_append_current_token(state);
            state.tokens := array_append(state.tokens, ')');
            state.parentheses_stack := state.parentheses_stack - 1;
        END IF;
    ELSIF state.current_char = '"' THEN
        state.skip_for := position('"' IN substring(
            state.search_query FROM state.current_index + 1
        ));

        IF state.skip_for > 1 THEN
            state.tokens = array_append(
                state.tokens,
                substring(
                    state.search_query
                    FROM state.current_index FOR state.skip_for + 1
                )
            );
        ELSIF state.skip_for = 0 THEN
            state.current_token := state.current_token || state.current_char;
        END IF;
    ELSIF (
        state.current_char = '-' AND
        (state.current_index = 1 OR state.previous_char = ' ')
    ) THEN
        state.tokens := array_append(state.tokens, '-');
    ELSIF state.current_char = ' ' THEN
        state := tsq_append_current_token(state);
        IF substring(
            state.search_query FROM state.current_index FOR 4
        ) = ' or ' THEN
            state.skip_for := 2;

            -- remove duplicate OR tokens
            IF state.tokens[array_length(state.tokens, 1)] != ' | ' THEN
                state.tokens := array_append(state.tokens, ' | ');
            END IF;
        END IF;
    ELSE
        state.current_token = state.current_token || state.current_char;
    END IF;
    RETURN state;
END;
$$;


ALTER FUNCTION public.tsq_tokenize_character(state public.tsq_state) OWNER TO vagrant;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: categories; Type: TABLE; Schema: public; Owner: vagrant
--

CREATE TABLE public.categories (
    cat_id integer NOT NULL,
    name character varying(100) NOT NULL
);


ALTER TABLE public.categories OWNER TO vagrant;

--
-- Name: categories_cat_id_seq; Type: SEQUENCE; Schema: public; Owner: vagrant
--

CREATE SEQUENCE public.categories_cat_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.categories_cat_id_seq OWNER TO vagrant;

--
-- Name: categories_cat_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vagrant
--

ALTER SEQUENCE public.categories_cat_id_seq OWNED BY public.categories.cat_id;


--
-- Name: posecategories; Type: TABLE; Schema: public; Owner: vagrant
--

CREATE TABLE public.posecategories (
    posecat_id integer NOT NULL,
    pose_id integer NOT NULL,
    cat_id integer NOT NULL
);


ALTER TABLE public.posecategories OWNER TO vagrant;

--
-- Name: posecategories_posecat_id_seq; Type: SEQUENCE; Schema: public; Owner: vagrant
--

CREATE SEQUENCE public.posecategories_posecat_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.posecategories_posecat_id_seq OWNER TO vagrant;

--
-- Name: posecategories_posecat_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vagrant
--

ALTER SEQUENCE public.posecategories_posecat_id_seq OWNED BY public.posecategories.posecat_id;


--
-- Name: poses; Type: TABLE; Schema: public; Owner: vagrant
--

CREATE TABLE public.poses (
    pose_id integer NOT NULL,
    name character varying(100) NOT NULL,
    sanskrit character varying(100),
    sanskrit_unaccented character varying(100),
    description character varying(2000),
    difficulty character varying(20) NOT NULL,
    altnames character varying(100),
    benefit character varying(1000),
    img_url character varying(200) NOT NULL,
    is_leftright boolean,
    next_pose_str character varying(500),
    prev_pose_str character varying(500),
    next_poses json,
    search_vector tsvector
);


ALTER TABLE public.poses OWNER TO vagrant;

--
-- Name: poses_pose_id_seq; Type: SEQUENCE; Schema: public; Owner: vagrant
--

CREATE SEQUENCE public.poses_pose_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.poses_pose_id_seq OWNER TO vagrant;

--
-- Name: poses_pose_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vagrant
--

ALTER SEQUENCE public.poses_pose_id_seq OWNED BY public.poses.pose_id;


--
-- Name: poseworkouts; Type: TABLE; Schema: public; Owner: vagrant
--

CREATE TABLE public.poseworkouts (
    posework_id integer NOT NULL,
    pose_id integer NOT NULL,
    workout_id integer NOT NULL
);


ALTER TABLE public.poseworkouts OWNER TO vagrant;

--
-- Name: poseworkouts_posework_id_seq; Type: SEQUENCE; Schema: public; Owner: vagrant
--

CREATE SEQUENCE public.poseworkouts_posework_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.poseworkouts_posework_id_seq OWNER TO vagrant;

--
-- Name: poseworkouts_posework_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vagrant
--

ALTER SEQUENCE public.poseworkouts_posework_id_seq OWNED BY public.poseworkouts.posework_id;


--
-- Name: workouts; Type: TABLE; Schema: public; Owner: vagrant
--

CREATE TABLE public.workouts (
    workout_id integer NOT NULL,
    duration integer NOT NULL,
    name character varying(200),
    author character varying(200),
    description character varying(1000)
);


ALTER TABLE public.workouts OWNER TO vagrant;

--
-- Name: workouts_workout_id_seq; Type: SEQUENCE; Schema: public; Owner: vagrant
--

CREATE SEQUENCE public.workouts_workout_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.workouts_workout_id_seq OWNER TO vagrant;

--
-- Name: workouts_workout_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vagrant
--

ALTER SEQUENCE public.workouts_workout_id_seq OWNED BY public.workouts.workout_id;


--
-- Name: categories cat_id; Type: DEFAULT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.categories ALTER COLUMN cat_id SET DEFAULT nextval('public.categories_cat_id_seq'::regclass);


--
-- Name: posecategories posecat_id; Type: DEFAULT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.posecategories ALTER COLUMN posecat_id SET DEFAULT nextval('public.posecategories_posecat_id_seq'::regclass);


--
-- Name: poses pose_id; Type: DEFAULT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.poses ALTER COLUMN pose_id SET DEFAULT nextval('public.poses_pose_id_seq'::regclass);


--
-- Name: poseworkouts posework_id; Type: DEFAULT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.poseworkouts ALTER COLUMN posework_id SET DEFAULT nextval('public.poseworkouts_posework_id_seq'::regclass);


--
-- Name: workouts workout_id; Type: DEFAULT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.workouts ALTER COLUMN workout_id SET DEFAULT nextval('public.workouts_workout_id_seq'::regclass);


--
-- Data for Name: categories; Type: TABLE DATA; Schema: public; Owner: vagrant
--

COPY public.categories (cat_id, name) FROM stdin;
1	Standing
2	Balancing
3	Arm and Leg Support
4	Twist
5	Seated
6	Neutral
7	Supine
8	Prone
9	Backbend
10	Forward Bend
11	Lateral Bend
12	Arm Balance and Inversion
13	Chest Opening
14	Core & Abs
15	Hip Opening
16	Restorative
17	Strengthening
18	Back
19	Digestion
20	Energy
21	Fatigue
22	Flexibility
23	Headaches
24	Insomnia
25	Neck Pain
26	Stress
27	Arms
28	Shoulders
\.


--
-- Data for Name: posecategories; Type: TABLE DATA; Schema: public; Owner: vagrant
--

COPY public.posecategories (posecat_id, pose_id, cat_id) FROM stdin;
1	1	1
2	1	2
3	2	3
4	2	2
5	3	1
6	3	2
7	4	1
8	4	2
9	5	1
10	5	4
11	6	5
12	6	2
13	7	5
14	7	2
15	8	5
16	8	6
17	9	7
18	9	6
19	10	8
20	10	9
21	11	8
22	11	9
23	12	3
24	12	9
25	13	3
26	13	6
27	14	3
28	14	2
29	15	3
30	15	4
31	16	3
32	16	2
33	17	7
34	17	9
35	18	7
36	18	9
37	19	3
38	19	9
39	20	3
40	20	10
41	21	5
42	21	10
43	22	1
44	22	2
45	23	1
46	23	2
47	24	1
48	24	4
49	25	1
50	25	4
51	26	1
52	26	4
53	27	8
54	27	10
55	28	8
56	28	10
57	29	8
58	29	10
59	30	8
60	30	10
61	31	8
62	31	9
63	32	7
64	32	6
65	33	8
66	33	6
67	34	3
68	34	9
69	35	5
70	35	4
71	36	5
72	36	4
73	37	1
74	37	2
75	38	1
76	38	6
77	39	1
78	39	2
79	40	1
80	40	4
81	41	1
82	41	4
83	42	1
84	42	4
85	43	1
86	43	2
87	44	1
88	44	2
89	45	1
90	45	2
91	46	1
92	46	6
93	47	1
94	47	2
95	48	1
96	48	4
97	49	1
98	49	4
99	50	1
100	50	4
101	51	1
102	51	2
103	52	1
104	52	2
105	53	1
106	53	11
107	54	12
108	54	2
109	55	5
110	55	2
111	56	12
112	56	2
113	57	12
114	57	4
115	58	5
116	58	4
117	59	12
118	59	10
119	60	3
120	60	10
121	61	3
122	61	2
123	62	3
124	62	2
125	63	3
126	63	2
127	64	3
128	64	10
129	65	3
130	65	10
131	66	3
132	66	2
133	67	3
134	67	2
135	68	3
136	68	2
137	69	3
138	69	2
139	70	3
140	70	2
141	71	3
142	71	4
143	72	1
144	72	2
145	73	5
146	73	6
147	74	12
148	74	2
149	75	8
150	75	9
151	76	5
152	76	6
153	77	12
154	77	2
155	78	7
156	78	9
157	79	12
158	79	2
159	80	12
160	80	2
161	81	5
162	81	10
163	82	5
164	82	10
165	83	1
166	83	10
167	84	1
168	84	10
169	85	3
170	85	6
171	86	5
172	86	2
173	87	1
174	87	10
175	88	1
176	88	2
177	89	1
178	89	2
179	90	1
180	90	4
181	91	1
182	91	10
183	92	1
184	92	2
185	93	1
186	93	2
187	94	7
188	94	6
189	95	7
190	95	6
191	96	12
192	96	2
193	97	12
194	97	2
195	98	7
196	98	2
197	99	1
198	99	2
199	100	1
200	100	2
201	101	12
202	101	2
203	102	3
204	102	10
205	103	12
206	103	2
207	104	3
208	104	10
209	105	12
210	105	2
211	106	12
212	106	2
213	107	5
214	107	9
215	108	7
216	108	9
217	109	7
218	109	6
219	110	5
220	110	9
221	111	5
222	111	9
223	112	5
224	112	9
225	113	1
226	113	2
227	114	8
228	114	9
229	115	8
230	115	9
231	116	1
232	116	2
233	117	1
234	117	2
235	118	5
236	118	6
237	119	5
238	119	6
239	120	3
240	120	2
241	121	3
242	121	2
243	122	3
244	122	4
245	123	3
246	123	2
247	124	3
248	124	2
249	125	3
250	125	2
251	126	3
252	126	4
253	127	3
254	127	2
255	128	5
256	128	4
257	129	5
258	129	4
259	130	1
260	130	6
261	131	1
262	131	9
263	132	12
264	132	2
265	133	3
266	133	9
267	134	12
268	134	6
269	135	7
270	135	6
271	136	3
272	136	2
273	137	3
274	137	2
275	138	3
276	138	2
277	139	3
278	139	2
279	140	3
280	140	9
281	141	3
282	141	2
283	142	3
284	142	2
285	143	3
286	143	2
287	144	12
288	144	10
289	145	3
290	145	10
291	146	3
292	146	10
293	147	3
294	147	10
295	148	3
296	148	10
297	149	7
298	149	2
299	150	12
300	150	2
301	151	12
302	151	2
303	152	12
304	152	2
305	153	12
306	153	2
307	154	12
308	154	2
309	155	1
310	155	4
311	156	1
312	156	11
313	157	1
314	157	4
315	158	1
316	158	4
317	159	5
318	159	10
319	160	8
320	160	9
321	161	7
322	161	4
323	162	5
324	162	2
325	163	5
326	163	2
327	164	1
328	164	2
329	165	5
330	165	2
331	166	5
332	166	2
333	167	5
334	167	4
335	168	5
336	168	4
337	169	5
338	169	6
339	170	3
340	170	9
341	171	3
342	171	2
343	172	3
344	172	9
345	173	1
346	173	10
347	174	1
348	174	10
349	175	1
350	175	2
351	176	1
352	176	11
353	177	1
354	177	2
355	178	1
356	178	4
357	179	3
358	179	9
359	180	1
360	180	11
361	181	1
362	181	4
363	182	1
364	182	2
365	183	1
366	183	2
367	184	1
368	184	2
369	185	1
370	185	10
371	186	1
372	186	10
373	187	1
374	187	2
375	188	1
376	188	11
377	189	1
378	189	2
379	190	3
380	190	9
381	191	3
382	191	2
383	192	3
384	192	9
385	193	7
386	193	10
387	194	7
388	194	10
389	10	13
390	19	13
391	31	13
392	34	13
393	78	13
394	85	13
395	114	13
396	116	13
397	160	13
398	190	13
399	170	13
400	179	13
401	192	13
402	6	14
403	7	14
404	20	14
405	22	14
406	54	14
407	62	14
408	60	14
409	63	14
410	171	14
411	98	14
412	129	14
413	88	14
414	142	14
415	8	15
416	9	15
417	29	15
418	35	15
419	36	15
420	72	15
421	73	15
422	92	15
423	93	15
424	94	15
425	95	15
426	76	15
427	112	15
428	111	15
429	128	15
430	129	15
431	159	15
432	168	15
433	30	15
434	161	15
435	163	15
436	27	16
437	28	16
438	32	16
439	33	16
440	98	16
441	9	16
442	95	16
443	94	16
444	108	16
445	135	16
446	193	16
447	194	16
448	161	16
449	6	17
450	22	17
451	62	17
452	60	17
453	64	17
454	156	17
455	176	17
456	132	17
457	171	17
458	86	17
459	96	17
460	114	17
461	168	17
462	136	17
463	157	17
464	178	17
465	138	17
466	190	17
467	140	17
468	182	17
469	187	17
470	189	17
471	118	18
472	119	18
473	10	18
474	11	18
475	17	18
476	19	18
477	20	18
478	34	18
479	60	18
480	64	18
481	72	18
482	156	18
483	176	18
484	76	18
485	78	18
486	88	18
487	114	18
488	129	18
489	144	18
490	94	18
491	21	18
492	157	18
493	178	18
494	160	18
495	169	18
496	190	18
497	131	18
498	187	18
499	118	19
500	87	19
501	6	19
502	10	19
503	17	19
504	31	19
505	64	19
506	156	19
507	176	19
508	78	19
509	129	19
510	21	19
511	107	19
512	120	19
513	145	19
514	114	19
515	168	19
516	128	19
517	94	19
518	108	19
519	157	19
520	176	19
521	21	19
522	81	19
523	83	19
524	101	19
525	153	19
526	17	20
527	19	20
528	31	20
529	64	20
530	129	20
531	133	20
532	116	20
533	110	20
534	112	20
535	160	20
536	179	20
537	190	20
538	87	21
539	8	21
540	10	21
541	19	21
542	27	21
543	28	21
544	31	21
545	32	21
546	60	21
547	64	21
548	78	21
549	129	21
550	88	21
551	98	21
552	21	21
553	81	21
554	114	21
555	144	21
556	160	21
557	83	21
558	153	21
559	140	21
560	131	21
561	179	21
562	192	21
563	87	22
564	8	22
565	28	22
566	35	22
567	75	22
568	64	22
569	176	22
570	76	22
571	86	22
572	81	22
573	145	22
574	146	22
575	133	22
576	116	22
577	168	22
578	110	22
579	111	22
580	128	22
581	94	22
582	108	22
583	178	22
584	95	22
585	93	22
586	83	22
587	91	22
588	164	22
589	140	22
590	182	22
591	163	22
592	87	23
593	17	23
594	32	23
595	60	23
596	64	23
597	75	23
598	76	23
599	81	23
600	21	23
601	144	23
602	108	23
603	87	24
604	17	24
605	20	24
606	32	24
607	34	24
608	60	24
609	64	24
610	73	24
611	75	24
612	76	24
613	21	24
614	144	24
615	108	24
616	81	24
617	83	24
618	101	24
619	153	24
620	20	25
621	28	25
622	32	25
623	34	25
624	75	25
625	176	25
626	87	26
627	6	26
628	28	26
629	32	26
630	62	26
631	132	26
632	76	26
633	96	26
634	98	26
635	118	26
636	144	26
637	81	26
638	83	26
639	101	26
640	153	26
641	54	27
642	55	27
643	62	27
644	60	27
645	64	27
646	74	27
647	93	27
648	132	27
649	77	27
650	171	27
651	96	27
652	133	27
653	114	27
654	79	27
655	80	27
656	57	27
657	138	27
658	101	27
659	190	27
660	170	27
661	150	27
662	140	27
663	179	27
664	131	27
665	192	27
666	87	28
667	83	28
668	10	28
669	19	28
670	20	28
671	31	28
672	34	28
673	62	28
674	60	28
675	72	28
676	75	28
677	132	28
678	77	28
679	88	28
680	96	28
681	133	28
682	116	28
683	129	28
684	162	28
685	167	28
686	168	28
687	144	28
688	79	28
689	80	28
690	128	28
691	108	28
692	157	28
693	138	28
694	160	28
695	153	28
696	170	28
697	140	28
698	189	28
\.


--
-- Data for Name: poses; Type: TABLE DATA; Schema: public; Owner: vagrant
--

COPY public.poses (pose_id, name, sanskrit, sanskrit_unaccented, description, difficulty, altnames, benefit, img_url, is_leftright, next_pose_str, prev_pose_str, next_poses, search_vector) FROM stdin;
1	Awkward	Utkaṭāsana	Utkatasana	From a standing position the heels come up and the arms are extended forward and parallel to the earth.  The fingers are together and the palms are facing down.  The knees are bent.  The pelvis is contracted under, the rib cage is lifted up and the chin is gently tucked toward the sternum.  Bandhas are engaged.  The gaze is to the front.	Beginner	\N	Improves overall body strength.  Opens pelvis.  Strengthens and tones the leg muscles.  Relieves menstrual cramping.  Reduces fat pocket under the buttocks.  Aligns the skeletal system.  Good for arthritis conditions.  Improves digestion.  Relieves joint pain.  Relieves sciatica.  Improves flexibility in the toes and the ankles.  Exercises the liver, the intestines and the pancreas.	static/img/awkward.png	\N	\N	\N	{"22": 1, "23": 1, "72": 1, "86": 1, "167": 1, "165": 1, "166": 1}	'arm':13 'awkward':1A 'bandha':56 'bent':35 'cage':43 'chin':49 'come':9 'contract':39 'earth':21 'engag':58 'extend':15 'face':30 'finger':23 'forward':16 'front':64 'gaze':60 'gentl':51 'heel':8 'knee':33 'lift':45 'palm':28 'parallel':18 'pelvi':37 'posit':6 'rib':42 'stand':5 'sternum':55 'togeth':25 'toward':53 'tuck':52 'utkatasana':2C
3	Bird of Paradise	Svarga Dvijāsana	Svarga Dvijasana	From Bound Revolved Chair (Parivṛtta Baddha Utkaṭāsana), one foot stays rooted into the earth and straightens while the opposite leg comes up with a bent knee.  Once you are standing upright extend the leg towards the sky.  The ribcage is lifted and the heart is open in the full expression of the pose.  The gaze is forward.	Expert	\N	Increases the flexibility of the spine and back and stretches the shoulders.  Strengthens the legs.  Increases flexibility of the hip and knee joints.  Improves balance.  Opens the groin.  Stretches the hamstrings.	static/img/chair_twist_bind_up_R.png	t	Bound Revolved Chair	Bound Revolved Chair	{"26": 1, "93": 1, "92": 1, "100": 1, "113": 1, "175": 1, "24": 1}	'baddha':11 'bent':30 'bird':1A 'bound':7 'chair':9 'come':26 'dvijasana':5C 'earth':19 'express':55 'extend':37 'foot':14 'forward':62 'full':54 'gaze':60 'heart':49 'knee':31 'leg':25,39 'lift':46 'one':13 'open':51 'opposit':24 'paradis':3A 'parivṛtta':10 'pose':58 'revolv':8 'ribcag':44 'root':16 'sky':42 'stand':35 'stay':15 'straighten':21 'svarga':4C 'toward':40 'upright':36 'utkaṭāsana':12
110	One Legged King Pigeon	Eka Pāda Rājakapotāsana	Eka Pada Rajakapotasana	From One Legged King Pigeon (Preparation), bend the back knee and bring the heel towards the back.  Bring the hands over the shoulders towards the back to catch the foot or toes.  Arch the back and drop the head slightly.  Use a strap if the hands cannot reach the foot.  Stabilize the body and keep the weight in the center line for balance.	Expert	\N	Stretches the thighs, groins, shoulders, hip flexors, spine and opens the hips and chest.	static/img/pigeon_king_R.png	t	Cow Face (Preparation)	One Legged King Pigeon - Mermaid	{"36": 1, "112": 1, "111": 1, "159": 1, "169": 1}	'arch':40 'back':16,24,33,42 'balanc':70 'bend':14 'bodi':60 'bring':19,25 'cannot':54 'catch':35 'center':67 'drop':44 'eka':5C 'foot':37,57 'hand':27,53 'head':46 'heel':21 'keep':62 'king':3A,11 'knee':17 'leg':2A,10 'line':68 'one':1A,9 'pada':6C 'pigeon':4A,12 'prepar':13 'rajakapotasana':7C 'reach':55 'shoulder':30 'slight':47 'stabil':58 'strap':50 'toe':39 'toward':22,31 'use':48 'weight':64
5	Revolved Bird of Paradise (Preparation)	\N	\N	From Revolved Chair (Parivṛtta Utkaṭāsana) pose, the lower arm reaches back around the legs as the upper arm wraps around the back and the fingers of the respective hands eventually meet and interlace.  The ribcage is lifted.  The gaze toward the sky, unless this brings pain to the neck, then the gaze is towards the earth.	Expert	\N	Increases the flexibility of the spine and back and stretches the shoulders.  Stretches the lower back.  Improves balance.  Powerful detoxification of toxic food, drinks, and thoughts.	static/img/bird_of_paradise_revolved_preparation_L.png	t	Revolved Bird of Paradise,Bound Revolved Crescent Lunge,Bound Revolved Side Angle	Revolved Bird of Paradise,Bound Revolved Crescent Lunge,Bound Revolved Side Angle	{"4": 1, "42": 1, "158": 1, "24": 1, "25": 1, "40": 1}	'arm':14,23 'around':17,25 'back':16,27 'bird':2A 'bring':50 'chair':8 'earth':61 'eventu':35 'finger':30 'gaze':44,57 'hand':34 'interlac':38 'leg':19 'lift':42 'lower':13 'meet':36 'neck':54 'pain':51 'paradis':4A 'parivṛtta':9 'pose':11 'prepar':5A 'reach':15 'respect':33 'revolv':1A,7 'ribcag':40 'sky':47 'toward':45,59 'unless':48 'upper':22 'utkaṭāsana':10 'wrap':24
117	Full Lord of the Dance	Naṭarājāsana	Natarajasana	From Mountain (Tāḍāsana) flex one knee and draw the foot up toward the hip.  Then clasp the foot with the hand on the same side of the body by rotating the elbow in and up while extending the leg back and up from the hip.  Lift the opposite arm overhead, bend the elbow and grasp the foot.  Gaze is up.  Maintain bandhas throughout the pose for stabilization.  Remember to keep the standing leg straight and strong while remaining aware of the tendency to lock the standing leg knee.  Keep the pelvis level to create symmetrical foundation for the full extension of the spine.  Press the tailbone back and down, expand the chest, press the lower tips of the shoulder blades forward and up to facilitate opening of the heart center.  If stable and at ease, release the crown of the head toward the arch of the foot and draw the elbows together.  Breathe!	Expert	\N	Stretches the shoulders, the chest, the thighs, the groins, and the abdomen.  Strengthens the legs and the ankles.  Improves balance.	static/img/lord_of_the_dance_full_R.png	t	Mountain	Lord of the Dance	{"130": 1, "116": 1, "189": 1, "88": 1}	'arch':150 'arm':55 'awar':85 'back':46,113 'bandha':68 'bend':57 'blade':126 'bodi':34 'breath':159 'center':136 'chest':118 'clasp':22 'creat':100 'crown':144 'danc':5A 'draw':14,155 'eas':141 'elbow':38,59,157 'expand':116 'extend':43 'extens':106 'facilit':131 'flex':10 'foot':16,24,63,153 'forward':127 'foundat':102 'full':1A,105 'gaze':64 'grasp':61 'hand':27 'head':147 'heart':135 'hip':20,51 'keep':76,95 'knee':12,94 'leg':45,79,93 'level':98 'lift':52 'lock':90 'lord':2A 'lower':121 'maintain':67 'mountain':8 'natarajasana':6C 'one':11 'open':132 'opposit':54 'overhead':56 'pelvi':97 'pose':71 'press':110,119 'releas':142 'remain':84 'rememb':74 'rotat':36 'shoulder':125 'side':31 'spine':109 'stabil':73 'stabl':138 'stand':78,92 'straight':80 'strong':82 'symmetr':101 'tailbon':112 'tendenc':88 'throughout':69 'tip':122 'togeth':158 'toward':18,148 'tāḍāsana':9
6	Boat	Nāvāsana	Navasana	From a seated position the feet are lifted up so that the thighs are angled about 45-50 degrees relative to the earth.  The tailbone is lengthened into the earth and the pubis pulls toward the navel.  The shoulder blades are spread across the back and the hands reach around the back of the calves, with legs pulled towards the body.  The chin is tipped slightly toward the sternum so that the base of the skull lifts lightly away from the back of the neck.  Gaze is forward.	Intermediate	\N	Strengthens the abdomen, hip flexors, and spine.  Stimulates the kidneys, thyroid and prostate glands, and intestines.  Helps relieve stress.  Improves digestion.	static/img/boat_full.png	\N	Corpse	Half Boat,Corpse	{"32": 1, "7": 1, "21": 1, "149": 1, "81": 1, "82": 1, "169": 1}	'-50':20 '45':19 'across':45 'angl':17 'around':52 'away':81 'back':47,54,84 'base':75 'blade':42 'boat':1A 'bodi':63 'calv':57 'chin':65 'degre':21 'earth':25,32 'feet':8 'forward':90 'gaze':88 'hand':50 'leg':59 'lengthen':29 'lift':10,79 'light':80 'navasana':2C 'navel':39 'neck':87 'posit':6 'pubi':35 'pull':36,60 'reach':51 'relat':22 'seat':5 'shoulder':41 'skull':78 'slight':68 'spread':44 'sternum':71 'tailbon':27 'thigh':15 'tip':67 'toward':37,61,69
12	Half Bow	Ardha Dhanurāsana	Ardha Dhanurasana	From Box (Cakravākāsana), extend one arm forward and the opposite leg towards the back, keep the neck in line with the spine.  Bend the top knee and bring the extended hand backwards to catch the foot or toes.  Start to lift the knee and chest higher to create an arch like a bow.	Intermediate	\N	Stretches the back muscles and the front body.  Stimulates the abdominal organs and lungs.  Improves balance.	static/img/bow_half_R.png	t	Balancing the Cat,Box	Balancing the Cat	{"2": 1, "13": 1, "16": 1, "141": 1, "143": 1}	'arch':54 'ardha':3C 'arm':10 'back':18 'backward':36 'bend':27 'bow':2A,57 'box':6 'bring':32 'cakravākāsana':7 'catch':38 'chest':49 'creat':52 'dhanurasana':4C 'extend':8,34 'foot':40 'forward':11 'half':1A 'hand':35 'higher':50 'keep':19 'knee':30,47 'leg':15 'lift':45 'like':55 'line':23 'neck':21 'one':9 'opposit':14 'spine':26 'start':43 'toe':42 'top':29 'toward':16
9	Supine Bound Angle	Supta Baddha Koṇāsana	Supta Baddha Konasana	In supine position, bend both knees and drop the knees to each side, opening the hips.  Bring the soles of the feet together and bring the heels as close to the groin as possible, keeping the knees close to the ground.  Bring the hands overhead and interlace the fingers.  Keep the back flat on the floor.	Beginner	\N	Opens the hips and groins.  Stretches the shoulders, rib cage and back.  Stimulates the abdominal organs, lungs and heart.	static/img/supine_bound_angle.png	\N	Corpse	Corpse	{"32": 1, "98": 1, "194": 1, "94": 1, "135": 1, "161": 1, "193": 1}	'angl':3A 'back':58 'baddha':5C 'bend':10 'bound':2A 'bring':23,31,48 'close':35,44 'drop':14 'feet':28 'finger':55 'flat':59 'floor':62 'groin':38 'ground':47 'hand':50 'heel':33 'hip':22 'interlac':53 'keep':41,56 'knee':12,16,43 'konasana':6C 'open':20 'overhead':51 'posit':9 'possibl':40 'side':19 'sole':25 'supin':1A,8 'supta':4C 'togeth':29
11	Bow (Preparation)	\N	\N	From a prone position with the abdomen on the earth and the knees bent (and no wider than the hips) the hands grip the ankles (but not the tops of the feet) in preparation for Bow (Dhanurāsana) pose.  The gaze is down or forward.	Beginner	\N	Stretches the entire front of the body, ankles, thighs, groins, abdomen, chest, throat and deep hip flexors (psoas).  Strengthens the back muscles.  Improves posture.  Stimulates the organs of the abdomen and neck.	static/img/bow_preparation.png	\N	Bow,Front Corpse	Bow,Front Corpse	{"10": 1, "33": 1, "31": 1, "160": 1}	'abdomen':9 'ankl':27 'bent':16 'bow':1A,38 'dhanurāsana':39 'earth':12 'feet':34 'forward':46 'gaze':42 'grip':25 'hand':24 'hip':22 'knee':15 'pose':40 'posit':6 'prepar':2A,36 'prone':5 'top':31 'wider':19
8	Bound Angle	Baddha Koṇāsana	Baddha Konasana	In sitting position, bend both knees and drop the knees to each side, opening the hips.  Bring the soles of the feet together and bring the heels as close to the groin as possible, keeping the knees close to the ground.  The hands may reach down and grasp and maneuver the feet so that the soles are facing upwards and the heels and little toes are connected.  The shoulders should be pulled back and no rounding of the spine.	Beginner	\N	Opens the hips and groins.  Stretches the shoulders, rib cage and back.  Stimulates the abdominal organs, lungs and heart.	static/img/bound_angle.png	\N	\N	\N	{"111": 1, "119": 1, "21": 1, "169": 1, "81": 1, "76": 1, "118": 1}	'angl':2A 'back':77 'baddha':3C 'bend':8 'bound':1A 'bring':21,29 'close':33,42 'connect':71 'drop':12 'face':62 'feet':26,56 'grasp':52 'groin':36 'ground':45 'hand':47 'heel':31,66 'hip':20 'keep':39 'knee':10,14,41 'konasana':4C 'littl':68 'maneuv':54 'may':48 'open':18 'posit':7 'possibl':38 'pull':76 'reach':49 'round':80 'shoulder':73 'side':17 'sit':6 'sole':23,60 'spine':83 'toe':69 'togeth':27 'upward':63
7	Half Boat	Ardha Nāvāsana	Ardha Navasana	From a seated position the hands are gripped around the back of the legs and the knees are bent in a 90 degree angle.  Both legs are pulled in towards the abdomen.  The core is engaged to maintain balance on the sits bones (be sure that the back does not round).  The front of the torso lengthens between the pubis and top of the sternum as the spine extends in both directions reaching up to the sky and rooting down to the earth.  The gaze is forward and Bandhas are engaged.	Beginner	\N	Strengthens the abdomen, hip flexors and spine.  Stimulates the kidneys, thyroid, prostate glands and intestines.  Helps relieve stress.  Improves digestion.	static/img/boat_half.png	\N	Boat,Corpse	Corpse	{"6": 1, "32": 1, "84": 1, "21": 1, "149": 1, "81": 1, "82": 1, "169": 1}	'90':26 'abdomen':36 'angl':28 'ardha':3C 'around':13 'back':15,52 'balanc':43 'bandha':93 'bent':23 'boat':2A 'bone':47 'core':38 'degre':27 'direct':76 'earth':87 'engag':40,95 'extend':73 'forward':91 'front':57 'gaze':89 'grip':12 'half':1A 'hand':10 'knee':21 'leg':18,30 'lengthen':61 'maintain':42 'navasana':4C 'posit':8 'pubi':64 'pull':32 'reach':77 'root':83 'round':55 'seat':7 'sit':46 'sky':81 'spine':72 'sternum':69 'sure':49 'top':66 'torso':60 'toward':34
18	One Legged Bridge	Eka Pāda Setu Bandha Sarvāṅgāsana	Eka Pada Setu Bandha Sarvangasana	From Bridge (Setu Bandha Sarvāṅgāsana) pose, begin to extend one leg out in front, without dropping the hips.  If possible, bring the extended leg higher, toes pointing towards the sky.	Intermediate	\N	Stretches the rib cage, chest, neck and back muscles.  Tightens the gluts.  Strengthens the legs, knees and thighs.	static/img/bridge_leg_up_R.png	t	Bridge	Bridge	{"17": 1, "32": 1}	'bandha':7C,12 'begin':15 'bridg':3A,10 'bring':29 'drop':24 'eka':4C 'extend':17,31 'front':22 'higher':33 'hip':26 'leg':2A,19,32 'one':1A,18 'pada':5C 'point':35 'pose':14 'possibl':28 'sarvangasana':8C 'sarvāṅgāsana':13 'setu':6C,11 'sky':38 'toe':34 'toward':36 'without':23
15	Box with Shoulder Stretch	\N	\N	From Box (Cakravākāsana), one arm extends under the body and stretches out in a perpendicular direction.  The opposite arm reaches straight forward while the forehead rest softly on the earth in the direction of the extended arm.  The gaze is to the side.	Beginner	\N	Gently stretches the hips, thighs, and ankles.  Calms the brain and helps relieve stress and fatigue.  Relieves back and neck pain when done with head and torso supported.  Stretches the shoulders.	static/img/box_hand_to_ankle_R.png	t	Box	Box	{"13": 1, "28": 1, "29": 1}	'arm':9,23,41 'bodi':13 'box':1A,6 'cakravākāsana':7 'direct':20,37 'earth':34 'extend':10,40 'forehead':29 'forward':26 'gaze':43 'one':8 'opposit':22 'perpendicular':19 'reach':24 'rest':30 'shoulder':3A 'side':47 'soft':31 'straight':25 'stretch':4A,15
16	One Legged Box	\N	\N	From Box (Cakravākāsana), one knee is resting squared to the earth.  The other leg is extended and reaches up towards the sky.  The gaze is towards the back.	Beginner	\N	Tones and strengthens the standing leg.  Improves flexibility.  Opens the hips.	static/img/downward_dog_leg_up_kneeling_R.png	t	One Legged Plank on the Knee	One Legged Plank on the Knee	{"141": 1, "14": 1, "13": 1, "2": 1, "12": 1, "136": 1, "143": 1}	'back':31 'box':3A,5 'cakravākāsana':6 'earth':14 'extend':19 'gaze':27 'knee':8 'leg':2A,17 'one':1A,7 'reach':21 'rest':10 'sky':25 'squar':11 'toward':23,29
19	Camel	Uṣṭrāsana	Ustrasana	From a kneeling position the knees are hip width apart and the thighs are perpendicular to the earth.  The inner thighs are narrowed and rotated slightly inward with the buttocks engaged but not hardened.  The tailbone is tucked under but the hips do not puff forward.  The shins and tops of the feet are pressed firmly into the earth.  The ribcage is open, along with the heart center, but the lower front ribs do not protrude sharply towards the sky.  The lower back lifts the ribs away from the pelvis to keep the lower spine as long as possible.  The base of the palms are pressed firmly against the soles (or heels) of the feet and the fingers are pointed toward the toes.  The arms are extended straight and are turned slightly outward at the shoulder joint so the elbow creases face forward without squeezing the shoulder blades together.  The neck is in a relatively neutral position, neither flexed nor extended, or (for the advanced practitioners only) the head drops back.  Be careful not to strain your neck and harden your throat.  The gaze is either towards the sky or towards the earth, depending upon your flexibility.	Intermediate	\N	Stretches the entire front of the body, the ankles, thighs and groins, abdomen and chest, and throat.  Stretches the deep hip flexors (psoas).  Strengthens back muscles.  Improves posture.  Stimulates the organs of the abdomen and neck.	static/img/camel.png	\N	Hero,Pigeon	Hero,Pigeon	{"107": 1, "133": 1, "10": 1, "148": 1}	'advanc':167 'along':66 'apart':12 'arm':127 'away':89 'back':85,173 'base':103 'blade':150 'buttock':32 'camel':1A 'care':175 'center':70 'creas':143 'depend':196 'drop':172 'earth':20,61,195 'either':188 'elbow':142 'engag':33 'extend':129,163 'face':144 'feet':55,117 'finger':120 'firm':58,109 'flex':161 'flexibl':199 'forward':48,145 'front':74 'gaze':186 'harden':36,182 'head':171 'heart':69 'heel':114 'hip':10,44 'inner':22 'inward':29 'joint':139 'keep':94 'knee':8 'kneel':5 'lift':86 'long':99 'lower':73,84,96 'narrow':25 'neck':153,180 'neither':160 'neutral':158 'open':65 'outward':135 'palm':106 'pelvi':92 'perpendicular':17 'point':122 'posit':6,159 'possibl':101 'practition':168 'press':57,108 'protrud':78 'puff':47 'relat':157 'rib':75,88 'ribcag':63 'rotat':27 'sharpli':79 'shin':50 'shoulder':138,149 'sky':82,191 'slight':28,134 'sole':112 'spine':97 'squeez':147 'straight':130 'strain':178 'tailbon':38 'thigh':15,23 'throat':184 'toe':125 'togeth':151 'top':52 'toward':80,123,189,193 'tuck':40 'turn':133 'upon':197 'ustrasana':2C 'width':11 'without':146
20	Cat	Marjaryāsana	Marjaryasana	From Box (Cakravākāsana), shift some weight to the palms.  The wrists, elbows and shoulders are in one line.  The abdomen is pulled in and up with the spine arched in a strong Cobra spine.  The crown of the head is towards the earth and the neck is relaxed.  The gaze is between the arms towards the belly.	Beginner	\N	Relieves the spine and neck.  Energizes the body.	static/img/cat.png	\N	Box,Cow	Cow	{"13": 1, "34": 4.0, "14": 1}	'abdomen':22 'arch':31 'arm':56 'belli':59 'box':4 'cakravākāsana':5 'cat':1A 'cobra':35 'crown':38 'earth':45 'elbow':14 'gaze':52 'head':41 'line':20 'marjaryasana':2C 'neck':48 'one':19 'palm':11 'pull':24 'relax':50 'shift':6 'shoulder':16 'spine':30,36 'strong':34 'toward':43,57 'weight':8 'wrist':13
21	Caterpillar	\N	\N	Start from Staff (Daṇḍāsana) pose.  Fold forward over the legs, allowing the back to round.  Hands can be on the floor, or may catch the shins/ankles/toes.  Sit on a blanket to support this pose if needed.	Beginner	\N	Stretches the spine and kidneys, compresses the stomach to improve digestion.	static/img/caterpillar.png	\N	\N	\N	{"163": 1, "169": 1, "81": 1, "36": 1, "119": 1, "129": 1, "82": 1}	'allow':12 'back':14 'blanket':31 'catch':25 'caterpillar':1A 'daṇḍāsana':5 'floor':22 'fold':7 'forward':8 'hand':17 'leg':11 'may':24 'need':37 'pose':6,35 'round':16 'shins/ankles/toes':27 'sit':28 'staff':4 'start':2 'support':33
10	Bow	Dhanurāsana	Dhanurasana	From a prone position with the abdomen on the earth, the hands grip the ankles (but not the tops of the feet) with knees no wider than the width of your hips.  The heels are lifted away from the buttocks and at the same time the thighs are lifted away from the earth working opposing forces as the heart center, hips and back open.  The gaze is forward.	Intermediate	\N	Stretches the entire front of the body, ankles, thighs and groins, abdomen and chest, and throat, and deep hip flexors (psoas).  Strengthens the back muscles.  Improves posture.  Stimulates the organs of the abdomen and neck.	static/img/bow.png	\N	Bow (Preparation),Front Corpse	Bow (Preparation)	{"11": 1, "33": 1, "19": 1, "31": 1, "114": 1, "115": 1, "160": 1, "179": 1}	'abdomen':9 'ankl':17 'away':39,52 'back':65 'bow':1A 'buttock':42 'center':62 'dhanurasana':2C 'earth':12,55 'feet':24 'forc':58 'forward':70 'gaze':68 'grip':15 'hand':14 'heart':61 'heel':36 'hip':34,63 'knee':26 'lift':38,51 'open':66 'oppos':57 'posit':6 'prone':5 'thigh':49 'time':47 'top':21 'wider':28 'width':31 'work':56
28	Extended Child's	Utthita Balāsana	Utthita Balasana	From a kneeling position, the toes and knees are together with most of the weight of the body resting on the heels of the feet.  The arms are by the side body and the fingers are relaxed.  The forehead rest softly onto the earth.  The gaze is down and inward.	Beginner	\N	Gently stretches the hips, thighs, and ankles.  Calms the brain and helps relieve stress and fatigue.  Relieves back and neck pain when done with head and torso supported.	static/img/child.png	\N	Box,Upward-Facing Dog	Box,Plank,Upward-Facing Dog	{"13": 1, "179": 1, "27": 1, "29": 1, "75": 1, "148": 1, "15": 1}	'arm':31 'balasana':4C 'bodi':22,36 'child':2A 'earth':48 'extend':1A 'feet':29 'finger':39 'forehead':43 'gaze':50 'heel':26 'inward':54 'knee':12 'kneel':7 'onto':46 'posit':8 'relax':41 'rest':23,44 'side':35 'soft':45 'toe':10 'togeth':14 'utthita':3C 'weight':19
23	Chair with Prayer Hands	\N	\N	From Chair (Utkaṭāsana), the hands come together at the heart in prayer position.  The gaze is forward.	Beginner	\N	Strengthens the ankles, thighs, calves, and spine.  Stimulates the abdominal organs, diaphragm, and the heart.  Reduces flat feet.	static/img/chair_prayer.png	\N	Chair,Revolved Chair	Chair,Revolved Chair	{"22": 1, "24": 1.5, "83": 1, "130": 1, "25": 1, "131": 1}	'chair':1A,6 'come':10 'forward':21 'gaze':19 'hand':4A,9 'heart':14 'posit':17 'prayer':3A,16 'togeth':11 'utkaṭāsana':7
25	Revolved Chair with Extended Arms	Utthita Parivṛtta Utkaṭāsana	Utthita Parivrtta Utkatasana	From Revolved Chair (Parivṛtta Utkaṭāsana), one arm reaches up to the sky and the other reaches down to the earth on the inside or the outside of the knee, depending upon your flexibility.  Keep the shoulder blades squeezed together and the fingers extended out.  The ribcage is lifted and the heart is open.  The gaze is towards the sky, unless it hurts your neck, then the gaze is towards the earth.	Intermediate	\N	Increases the flexibility of the spine and back and stretches the shoulders.  Strengthens the legs.  Increases flexibility of the hip and knee joints.  Improves balance.  Opens the groin and stretches the hamstrings.	static/img/chair_twist_extended_R.png	t	Revolved Chair,Bound Revolved Chair	Revolved Chair,Bound Revolved Chair	{"24": 1, "26": 1}	'arm':5A,15 'blade':45 'chair':2A,11 'depend':38 'earth':28,79 'extend':4A,51 'finger':50 'flexibl':41 'gaze':63,75 'heart':59 'hurt':70 'insid':31 'keep':42 'knee':37 'lift':56 'neck':72 'one':14 'open':61 'outsid':34 'parivrtta':7C 'parivṛtta':12 'reach':16,24 'revolv':1A,10 'ribcag':54 'shoulder':44 'sky':20,67 'squeez':46 'togeth':47 'toward':65,77 'unless':68 'upon':39 'utkatasana':8C 'utkaṭāsana':13 'utthita':6C
26	Bound Revolved Chair	Parivṛtta Baddha Utkaṭāsana	Parivrtta Baddha Utkatasana	From Revolved Chair (Parivṛtta Utkaṭāsana), the lower arm weaves in between the legs as the upper arm wraps around the back and the fingers interlace.  The ribcage is lifted.  The gaze toward the sky, unless it hurts your neck, then the gaze towards the earth.	Intermediate	\N	Increases the flexibility of the spine and back and stretches the shoulders.  Stretches the lower back.  Challenges the balance.  Powerful detoxification of toxic food, drink, and thoughts.	static/img/chair_twist_bind_R.png	t	Bird of Paradise,Revolved Chair with Extended Arms,Bound Side Angle	Bird of Paradise,Revolved Chair with Extended Arms,Bound Side Angle	{"3": 1, "25": 1, "155": 1, "23": 1, "24": 1}	'arm':14,23 'around':25 'back':27 'baddha':5C 'bound':1A 'chair':3A,9 'earth':51 'finger':30 'gaze':37,48 'hurt':43 'interlac':31 'leg':19 'lift':35 'lower':13 'neck':45 'parivrtta':4C 'parivṛtta':10 'revolv':2A,8 'ribcag':33 'sky':40 'toward':38,49 'unless':41 'upper':22 'utkatasana':6C 'utkaṭāsana':11 'weav':15 'wrap':24
24	Revolved Chair	Parivṛtta Utkaṭāsana	Parivrtta Utkatasana	From Chair with Prayer Hands, the upper body twists to one side with the heart opening towards the sky.  The bottom elbow is on the outside of the opposite knee and the upper elbow reaches towards the sky.  Gaze is towards the sky or to the earth if the neck is sensitive.	Beginner	\N	Stretches the lower back.  Increases the flexibility of the spine and back.  Stretches the shoulders.  Challenges the balance.  Powerful detoxification of toxic food, drink, thoughts, etc.	static/img/chair_twist_R.png	t	Chair with Prayer Hands,Revolved Chair with Extended Arms	Chair with Prayer Hands,Revolved Chair with Extended Arms	{"23": 1, "25": 1, "22": 1}	'bodi':12 'bottom':25 'chair':2A,6 'earth':51 'elbow':26,38 'gaze':43 'hand':9 'heart':19 'knee':34 'neck':54 'one':15 'open':20 'opposit':33 'outsid':30 'parivrtta':3C 'prayer':8 'reach':39 'revolv':1A 'sensit':56 'side':16 'sky':23,42,47 'toward':21,40,45 'twist':13 'upper':11,37 'utkatasana':4C
116	Lord of the Dance	Naṭarājāsana	Natarajasana	Begin from a standing position with the weight of the body on one foot as the opposite heel lifts up towards the buttocks with a bent knee.  The hand on the same side of the body as the bent knee reaches back to grasp the outside of the foot or ankle.  With the added resistance of the hand gripping the foot, the bent leg and foot is then lifted up away from the earth and the torso towards the back of the room until the thigh is parallel to the earth.  Then the arm on the same side of body as the standing leg extends up and forward to the front.  The gaze is forward.  Avoid compression in the lower back by actively lifting the pubis towards the navel while at the same time, pressing the tailbone towards the floor.	Intermediate	\N	Stretches the shoulders, the chest, the thighs, the groins and abdomen.  Strengthens the legs and the ankles.  Improves balance.	static/img/lord_of_the_dance_R.png	t	Full Lord of the Dance,Mountain	Mountain	{"117": 1, "130": 1, "189": 1, "19": 1, "88": 1, "164": 1}	'activ':128 'ad':59 'ankl':56 'arm':99 'avoid':121 'away':76 'back':47,85,126 'begin':6 'bent':31,44,68 'bodi':16,41,105 'buttock':28 'compress':122 'danc':4A 'earth':79,96 'extend':110 'floor':145 'foot':19,54,66,71 'forward':113,120 'front':116 'gaze':118 'grasp':49 'grip':64 'hand':34,63 'heel':23 'knee':32,45 'leg':69,109 'lift':24,74,129 'lord':1A 'lower':125 'natarajasana':5C 'navel':134 'one':18 'opposit':22 'outsid':51 'parallel':93 'posit':10 'press':140 'pubi':131 'reach':46 'resist':60 'room':88 'side':38,103 'stand':9,108 'tailbon':142 'thigh':91 'time':139 'torso':82 'toward':26,83,132,143 'weight':13
22	Chair	Utkaṭāsana	Utkatasana	From a standing position, the feet are together and rooted into the earth with toes actively lifted.  The knees are bent and the weight of the body is on the heels of the feet.  The pelvis is tucked in and the ribcage is lifted.  The neck is a natural extension of the spine.  The arms are lifted up toward the sky with the elbows straight and the biceps by the ears.  The hands can be together or separated and facing each other with the fingers spread wide.  The gaze is forward.	Beginner	\N	Strengthens the ankles, thighs, calves, and spine.  Stretches shoulders and chest.  Stimulates the abdominal organs, diaphragm, and heart.  Reduces flat feet.  Energizes the entire body.	static/img/chair.png	\N	Chair with Prayer Hands,Standing Forward Bend,Standing Forward Bend with Shoulder Opener,Mountain	Chair with Prayer Hands,Standing Forward Bend,Standing Forward Bend with Shoulder Opener,Mountain	{"23": 1, "83": 1.5, "84": 1, "130": 1.5, "72": 1.5, "131": 1, "24": 1, "25": 1, "26": 1}	'activ':18 'arm':57 'bent':23 'bicep':70 'bodi':29 'chair':1A 'ear':73 'earth':15 'elbow':66 'extens':52 'face':82 'feet':8,36 'finger':87 'forward':93 'gaze':91 'hand':75 'heel':33 'knee':21 'lift':19,46,59 'natur':51 'neck':48 'pelvi':38 'posit':6 'ribcag':44 'root':12 'separ':80 'sky':63 'spine':55 'spread':88 'stand':5 'straight':67 'toe':17 'togeth':10,78 'toward':61 'tuck':40 'utkatasana':2C 'weight':26 'wide':89
35	Cow Face	Gomukhāsana	Gomukhasana	From Cow Face (Preparation), one arm reaches up and back from above the shoulder while the opposite arm reaches down and back from under the shoulder and around the torso into a bind at the center of the upper back.  The gaze is forward.	Intermediate	\N	Stretches the ankles, hips and thighs.  Stretches the shoulders, armpits, triceps, and chest.	static/img/knee_pile_bind_R.png	t	Cow Face (Preparation)	Cow Face (Preparation)	{"36": 1, "119": 1, "76": 1, "128": 1, "129": 1, "169": 1}	'arm':9,21 'around':31 'back':13,25,43 'bind':36 'center':39 'cow':1A,5 'face':2A,6 'forward':47 'gaze':45 'gomukhasana':3C 'one':8 'opposit':20 'prepar':7 'reach':10,22 'shoulder':17,29 'torso':33 'upper':42
30	Wide Child's with Side Stretch	\N	\N	From Wide Child's (Balāsana), the forehead rolls to one side and then the other.	Beginner	\N	Gently stretches the hips, thighs, and ankles.  Calms the brain and helps relieve stress and fatigue.  Relieves back and neck pain when done with head and torso supported.	static/img/child_wide_side_lean_R.png	\N	Wide Child's	Wide Child's	{"29": 1, "28": 1, "13": 1, "15": 1}	'balāsana':11 'child':2A,9 'forehead':13 'one':16 'roll':14 'side':5A,17 'stretch':6A 'wide':1A,8
36	Cow Face (Preparation)	\N	\N	From a seated position both sit bones are equally grounded into the earth with one knee wrapped on top of the other knee.  The feet extend to the side of the body and rest on the earth.  The ribcage is lifted towards the sky.  The chin is slightly tucked toward the sternum.  The hands are resting on the earth by the feet.  The gaze is forward.	Beginner	\N	Stretches the ankles, hips and thighs.	static/img/knee_pile_R.png	t	Box,Cow Face,Marichi's I	Cow Face,One Legged King Pigeon,One Legged King Pigeon (Preparation),One Legged King Pigeon - Mermaid,Front Splits	{"13": 1, "35": 1, "128": 1, "8": 1, "129": 1, "169": 1, "76": 1}	'bodi':35 'bone':10 'chin':49 'cow':1A 'earth':16,40,62 'equal':12 'extend':29 'face':2A 'feet':28,65 'forward':69 'gaze':67 'ground':13 'hand':57 'knee':19,26 'lift':44 'one':18 'posit':7 'prepar':3A 'rest':37,59 'ribcag':42 'seat':6 'side':32 'sit':9 'sky':47 'slight':51 'sternum':55 'top':22 'toward':45,53 'tuck':52 'wrap':20
34	Cow	Bitilāsana	Bitilasana	From Box (Cakravākāsana), the ribcage is lifted with a gentle sway in the low back.  The tailbone lifts up into dog tilt.  The eyes are soft and the gaze is to the sky.	Beginner	\N	Removes fatigue.  Improves breathing and the circulation of blood to the brain.  Rejuvenates the entire body.	static/img/dog.png	\N	Cat	Box,Cat	{"20": 2.5, "2": 1, "160": 1, "17": 1, "64": 1, "65": 1, "13": 1}	'back':17 'bitilasana':2C 'box':4 'cakravākāsana':5 'cow':1A 'dog':23 'eye':26 'gaze':31 'gentl':12 'lift':9,20 'low':16 'ribcag':7 'sky':35 'soft':28 'sway':13 'tailbon':19 'tilt':24
86	Garland	Mālāsana	Malasana	From a squatting position the feet are as close together as possible (keep your heels on the floor if you can; otherwise, support them on a folded mat).  The thighs are slightly wider than the torso.  The torso is leaning gently forward and tucked snugly between the thighs.  The elbows are pressed against the inner knees and the palms are together in Anjali Mudra (Salutation Seal).  The knees resist the elbows to help lengthen the front torso.  The gaze is soft and forward.	Beginner	\N	Stretches the ankles, groins and back torso.  Tones the belly.	static/img/garland.png	\N	\N	\N	{"7": 1, "6": 1, "81": 1, "169": 1, "55": 1, "54": 1, "168": 1, "167": 1, "165": 1, "166": 1, "123": 1}	'anjali':65 'close':11 'elbow':52,73 'feet':8 'floor':20 'fold':29 'forward':44,85 'front':78 'garland':1A 'gaze':81 'gentl':43 'heel':17 'help':75 'inner':57 'keep':15 'knee':58,70 'lean':42 'lengthen':76 'malasana':2C 'mat':30 'mudra':66 'otherwis':24 'palm':61 'posit':6 'possibl':14 'press':54 'resist':71 'salut':67 'seal':68 'slight':34 'snug':47 'soft':83 'squat':5 'support':25 'thigh':32,50 'togeth':12,63 'torso':38,40,79 'tuck':46 'wider':35
124	Lunge on the Knee	\N	\N	The front knee is bent in a 90-degree angle directly above the ankle and the back knee is resting on the earth with the top of the back foot pressed firmly into the earth.  The hips are squared and pressed forward.  The inner thighs scissor towards each other.  The pelvis is tucked under to protect.  The ribcage is lifted.  The arms are on either side of the front foot for balance.  The gaze is forward.	Beginner	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.	static/img/lunge_kneeling_R.png	t	Crescent Lunge on the Knee,Standing Forward Bend,Lunge,Lunge on the Knee with Arm Extended Forward,Pyramid on the Knee,Standing Splits	Crescent Lunge,Crescent Lunge on the Knee,Crescent Lunge Twist on the Knee,Downward-Facing Dog with Bent Knees,Downward-Facing Dog with Knee to Forehead,One Legged Downward-Facing Dog,Standing Forward Bend,Halfway Lift,Lunge,Lunge on the Knee with Arm Extended Forward,Lunge on the Knee with Arm Extended Up,Pyramid on the Knee,Reverse Warrior,Warrior II	{"45": 1, "83": 1, "120": 1, "125": 1, "147": 1, "164": 1, "143": 1, "141": 1}	'90':12 'angl':14 'ankl':18 'arm':66 'back':21,33 'balanc':76 'bent':9 'degre':13 'direct':15 'earth':27,39 'either':69 'firm':36 'foot':34,74 'forward':46,80 'front':6,73 'gaze':78 'hip':41 'inner':48 'knee':4A,7,22 'lift':64 'lung':1A 'pelvi':55 'press':35,45 'protect':60 'rest':24 'ribcag':62 'scissor':50 'side':70 'squar':43 'thigh':49 'top':30 'toward':51 'tuck':57
38	Crescent Lunge with Prayer Hands	\N	\N	The foot of the front leg is rooted into the earth with the knee directly above and tracking the ankle at a 90 degree angle.  The back leg is straight, no bend in the knee, and the weight is distributed backwards onto the toes as the back heel pushes back and down towards the earth.  The inner thighs scissor towards each other and the pelvis is tucked under with the ribcage lifted and the chin slightly tucked under.  The spine is long and extended.  The heart is open.  The hands are in prayer position.	Intermediate	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, back, abdomen, and groin (psoas muscles).  Strengthens and stretches the thighs, calves and ankles.	static/img/lunge_prayer_R.png	t	Crescent Lunge,Revolved Crescent Lunge	Crescent Lunge,Revolved Crescent Lunge	{"37": 1, "40": 1, "39": 1, "42": 1, "43": 1, "120": 1, "124": 1, "182": 1}	'90':28 'angl':30 'ankl':25 'back':32,52,55 'backward':46 'bend':37 'chin':80 'crescent':1A 'degre':29 'direct':20 'distribut':45 'earth':16,60 'extend':89 'foot':7 'front':10 'hand':5A,95 'heart':91 'heel':53 'inner':62 'knee':19,40 'leg':11,33 'lift':77 'long':87 'lung':2A 'onto':47 'open':93 'pelvi':70 'posit':99 'prayer':4A,98 'push':54 'ribcag':76 'root':13 'scissor':64 'slight':81 'spine':85 'straight':35 'thigh':63 'toe':49 'toward':58,65 'track':23 'tuck':72,82 'weight':43
40	Revolved Crescent Lunge	Parivṛtta Aṅjaneyāsana	Parivrtta Anjaneyasana	From Crescent Lunge with Prayer Hands, slowly twist the spine to one side, hooking the elbow outside of the knee.  Stack the shoulders on top of each other, keep the heart open and gaze up towards the sky.  On the inhale, elongate the spine and on the exhale take the twist slightly deeper.	Intermediate	\N	Lengthens and stretches the spine.  Creates flexibility in the rib cage.  Stimulates the internal abdominal organs and kidneys.	static/img/lunge_twist_R.png	t	Crescent Lunge with Prayer Hands,Revolved Crescent Lunge with Extended Arms	Crescent Lunge with Prayer Hands,Revolved Crescent Lunge with Extended Arms	{"38": 1, "41": 1, "24": 1, "42": 1}	'anjaneyasana':5C 'crescent':2A,7 'deeper':58 'elbow':21 'elong':47 'exhal':53 'gaze':39 'hand':11 'heart':36 'hook':19 'inhal':46 'keep':34 'knee':25 'lung':3A,8 'one':17 'open':37 'outsid':22 'parivrtta':4C 'prayer':10 'revolv':1A 'shoulder':28 'side':18 'sky':43 'slight':57 'slowli':12 'spine':15,49 'stack':26 'take':54 'top':30 'toward':41 'twist':13,56
31	Cobra	Bhujaṅgāsana	Bhujangasana	From a prone position lying on the earth the pelvic bowl is firmly contracted interiorly towards the center line of the body while the pubis is tucked under.  The legs are extended back and the tops of the feet are squared to the earth.  The palms are flat and the fingers are in line with the shoulder blades, or, if possible, the palms are tucked under the shoulders with the elbows bent and tucked into the sides of the body.  On an inhalation, the arms are straightened slightly, maintaining a soft bend in the elbows as the chest lifts off the earth.  Lift up only to the height that is comfortable and that also maintains the pubis and the legs pressed to the earth.  Work the opposing forces by pressing the tailbone towards the pubis as the pubis lifts towards the navel.  The hip points are narrowed.  The buttocks are firm but not hardened.  The shoulder blades are firm against the back.  The side ribs expand to facilitate the back bend.  Lift through the top of the sternum but avoid pushing the front ribs forward, which only hardens the lower back.  Distribute the backbend evenly throughout the entire spine.  The gaze is out in front or straight ahead depending on flexibility.	Beginner	\N	Strengthens the spine.  Stretches the chest, the lungs, the shoulders and the abdomen.  Firms the buttocks.  Stimulates the abdominal organs.  Helps relieve stress and fatigue.  Opens the heart and the lungs.  Soothes the sciatica.  Therapeutic for asthma.  Traditional texts say that Bhujangasana increases body heat, destroys disease, and awakens Kundalini.	static/img/cobra.png	\N	Front Corpse	Front Corpse	{"33": 1, "160": 1, "136": 1, "171": 1, "179": 1}	'ahead':210 'also':116 'arm':87 'avoid':182 'back':35,164,172,193 'backbend':196 'bend':94,173 'bent':74 'bhujangasana':2C 'blade':60,159 'bodi':24,82 'bowl':13 'buttock':151 'center':20 'chest':100 'cobra':1A 'comfort':113 'contract':16 'depend':211 'distribut':194 'earth':10,46,104,126 'elbow':73,97 'entir':200 'even':197 'expand':168 'extend':34 'facilit':170 'feet':41 'finger':53 'firm':15,153,161 'flat':50 'flexibl':213 'forc':130 'forward':187 'front':185,207 'gaze':203 'harden':156,190 'height':110 'hip':146 'inhal':85 'interior':17 'leg':32,122 'lie':7 'lift':101,105,141,174 'line':21,56 'lower':192 'maintain':91,117 'narrow':149 'navel':144 'oppos':129 'palm':48,65 'pelvic':12 'point':147 'posit':6 'possibl':63 'press':123,132 'prone':5 'pubi':27,119,137,140 'push':183 'rib':167,186 'shoulder':59,70,158 'side':79,166 'slight':90 'soft':93 'spine':201 'squar':43 'sternum':180 'straight':209 'straighten':89 'tailbon':134 'throughout':198 'top':38,177 'toward':18,135,142 'tuck':29,67,76 'work':127
46	Crescent Lunge on the Knee with Prayer Hands	\N	\N	From Crescent Lunge pose, bend the back knee and lower it to the floor with the top foot flat.  Tuck the pelvis under, lift the sternum and lower the hands to heart center into prayer hands.  Stack the front knee directly above the ankle.	Beginner	\N	Simpler version of Crescent Lunge pose.  Stretches the chest, lungs, and the back muscles.  Strengthens and stretches the thighs.	static/img/lunge_kneeling_prayer_R.png	t	Crescent Lunge on the Knee,Revolved Crescent Lunge on the Knee	Crescent Lunge on the Knee,Revolved Crescent Lunge on the Knee	{"45": 1, "48": 1, "147": 1, "124": 1, "120": 1, "51": 1, "37": 1}	'ankl':52 'back':15 'bend':13 'center':41 'crescent':1A,10 'direct':49 'flat':27 'floor':22 'foot':26 'front':47 'hand':8A,38,44 'heart':40 'knee':5A,16,48 'lift':32 'lower':18,36 'lung':2A,11 'pelvi':30 'pose':12 'prayer':7A,43 'stack':45 'sternum':34 'top':25 'tuck':28
45	Crescent Lunge on the Knee	Aṅjaneyāsana	Anjaneyasana	The front knee is bent in a 90-degree angle directly above the ankle and the back knee is resting on the earth with the top of the back foot pressed firmly into the earth.  The hips are squared and pressed forward.  The inner thighs scissor towards each other.  The pelvis is tucked under to protect the low back.  The ribcage is lifted.  The arms are lifted.  The hands can be together or separated and facing each other with the fingers spread wide.  The gaze is forward.	Beginner	\N	Stretches the chest, lungs, neck, belly and groin (psoas).  Strengthens the shoulders, arms and back muscles.  Strengthens and stretches the thighs, calves and ankles.	static/img/warrior_I_kneeling_R.png	t	Crescent Lunge on the Knee with Prayer Hands,Crescent Lunge Forward Bend on the Knee,Crescent Lunge Twist on the Knee,Standing Forward Bend,Lunge on the Knee,Pyramid on the Knee,Four Limbed Staff	Crescent Lunge on the Knee with Prayer Hands,Crescent Lunge Forward Bend on the Knee,Crescent Lunge Twist on the Knee,Lunge on the Knee,Pyramid on the Knee	{"46": 1, "47": 1, "51": 1, "83": 1, "124": 1, "147": 1, "171": 1, "120": 1, "37": 1}	'90':14 'angl':16 'anjaneyasana':6C 'ankl':20 'arm':71 'back':23,35,65 'bent':11 'crescent':1A 'degre':15 'direct':17 'earth':29,41 'face':82 'finger':87 'firm':38 'foot':36 'forward':48,93 'front':8 'gaze':91 'hand':75 'hip':43 'inner':50 'knee':5A,9,24 'lift':69,73 'low':64 'lung':2A 'pelvi':57 'press':37,47 'protect':62 'rest':26 'ribcag':67 'scissor':52 'separ':80 'spread':88 'squar':45 'thigh':51 'togeth':78 'top':32 'toward':53 'tuck':59 'wide':89
125	Lunge on the Knee with Arm Extended Forward	\N	\N	From Lunge on the Knee, the arm (on the side of the body that correlates to the front bent knee) is extended forward with fingers spread wide and the palm facing inward.  The other arm remains on the inside of the thigh with the palm rooted into the earth for support.  The gaze is forward.	Beginner	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Opens the shoulders.	static/img/lunge_kneeling_arm_forward_R.png	t	Lunge on the Knee,Lunge on the Knee with Arm Extended Up	Lunge on the Knee	{"124": 1, "126": 1, "120": 1, "143": 1, "141": 1}	'arm':6A,15,43 'bent':27 'bodi':21 'correl':23 'earth':57 'extend':7A,30 'face':39 'finger':33 'forward':8A,31,63 'front':26 'gaze':61 'insid':47 'inward':40 'knee':4A,13,28 'lung':1A,10 'palm':38,53 'remain':44 'root':54 'side':18 'spread':34 'support':59 'thigh':50 'wide':35
130	Mountain	Tāḍāsana	Tadasana	The body is in the standing position, with the feet together and rooted into the earth.  The toes are actively lifted.  The weight of the body is evenly distributed on the four corners of the feet.  The pelvis is tucked.  The ribcage is lifted.  The neck is a natural extension of the spine and the chin is slightly tucked towards the sternum.  The shoulders are relaxed as they rotate back and down.  The hands come together at the heart in prayer position.  The gaze is forward.	Beginner	\N	Improves posture.  Strengthens thighs, knees, and ankles.  Firms abdomen and buttocks.  Relieves sciatica.  Reduces flat feet.	static/img/mountain.png	\N	Chair,Eagle,Standing Head to Knee (Preparation),Standing Knee to Chest,Lord of the Dance,Mountain with Arms Up,Tree	Chair,Eagle,Extended Standing Hand to Toe,Standing Head to Knee,Standing Head to Knee (Preparation),Lord of the Dance,Full Lord of the Dance,Mountain with Arms Up,Tree	{"22": 1.5, "72": 1, "100": 1, "113": 1, "116": 1, "131": 2.0, "175": 1, "182": 1, "84": 1, "83": 1, "189": 1}	'activ':22 'back':72 'bodi':4,28 'chin':58 'come':77 'corner':35 'distribut':31 'earth':18 'even':30 'extens':52 'feet':12,38 'forward':88 'four':34 'gaze':86 'hand':76 'heart':81 'lift':23,46 'mountain':1A 'natur':51 'neck':48 'pelvi':40 'posit':9,84 'prayer':83 'relax':68 'ribcag':44 'root':15 'rotat':71 'shoulder':66 'slight':60 'spine':55 'stand':8 'sternum':64 'tadasana':2C 'toe':20 'togeth':13,78 'toward':62 'tuck':42,61 'weight':25
128	Marichi's I	Marīchyāsana I	Marichyasana I	From a seated position, one leg is extended to the front as the opposite leg bends with the heel next to the sits bone.  The torso is rotated towards the bent knee with one arm wrapped around the outside of that thigh.  The opposite arm reaches around and behind the body and the palm is rooted into the earth .  The ribcage is lifted and the heart is open.  The gaze follows the movement of the twist.	Intermediate	\N	Stimulates the liver and kidneys.  Stretches the shoulders, hips, and neck.  Energizes the spine.  Stimulates the digestive fire in the belly.  Relieves menstrual discomfort, fatigue, sciatica, and backache.  Therapeutic for asthma and infertility.	static/img/marichi_I_L.png	t	Marichi's III,Staff	Cow Face (Preparation),Staff	{"129": 1, "169": 1, "36": 1, "81": 1}	'arm':37,47 'around':39,49 'behind':51 'bend':18 'bent':33 'bodi':53 'bone':26 'earth':61 'extend':10 'follow':73 'front':13 'gaze':72 'heart':68 'heel':21 'knee':34 'leg':8,17 'lift':65 'marichi':1A 'marichyasana':2C 'movement':75 'next':22 'one':7,36 'open':70 'opposit':16,46 'outsid':41 'palm':56 'posit':6 'reach':48 'ribcag':63 'root':58 'rotat':30 'seat':5 'sit':25 'thigh':44 'torso':28 'toward':31 'twist':78 'wrap':38
49	Revolved Crescent Lunge on the Knee with Extended Arms	Utthita Parivṛtta Aṅjaneyāsana	Utthita Parivrtta Anjaneyasana	From Revolved Crescent Lunge on the Knee (Parivṛtta Aṅjaneyāsana), slowly release the hands.  Bottom hand can touch the floor or float, if needed, use a block to support.  Top hand reaches up towards the sky.  Keep both hands straight and heart remains open.  Gaze is upwards towards the top hand.	Intermediate	\N	In addition to the benefits from Revolved Crescent Lunge on the Knee (Parivṛtta Aṅjaneyāsana) pose, it opens the shoulders and strengthens the back muscles.	static/img/lunge_kneeling_twist_extended_R.png	t	Revolved Crescent Lunge on the Knee,Bound Revolved Crescent Lunge on the Knee	Revolved Crescent Lunge on the Knee,Bound Revolved Crescent Lunge on the Knee	{"48": 1, "50": 1, "41": 1, "45": 1, "124": 1, "123": 1}	'anjaneyasana':12C 'arm':9A 'aṅjaneyāsana':21 'block':38 'bottom':26 'crescent':2A,15 'extend':8A 'float':33 'floor':31 'gaze':56 'hand':25,27,42,50,62 'heart':53 'keep':48 'knee':6A,19 'lung':3A,16 'need':35 'open':55 'parivrtta':11C 'parivṛtta':20 'reach':43 'releas':23 'remain':54 'revolv':1A,14 'sky':47 'slowli':22 'straight':51 'support':40 'top':41,61 'touch':29 'toward':45,59 'upward':58 'use':36 'utthita':10C
50	Bound Revolved Crescent Lunge on the Knee	Parivṛtta Baddha Aṅjaneyāsana	Parivrtta Baddha Anjaneyasana	From Revolved Crescent Lunge on the Knee with Extended Arms (Utthita Parivṛtta Aṅjaneyāsana), lower the top hand around the back with palm facing out.  Bottom hand wraps underneath the thigh.  Bend the elbow and extend the hand to reach the other hand.  Bind the hands together.  If the hands cannot reach, use a strap.  Heart is open.  The gaze is over the top shoulder.	Intermediate	\N	Deeply stretches the spine, chest, lungs, shoulders and groin.  Stimulates the internal abdominal organs and kidneys.	static/img/lunge_kneeling_twist_extended_bound_R.png	t	Revolved Crescent Lunge on the Knee with Extended Arms	Revolved Crescent Lunge on the Knee with Extended Arms	{"49": 1, "126": 1, "124": 1, "120": 1}	'anjaneyasana':10C 'arm':20 'around':28 'aṅjaneyāsana':23 'back':30 'baddha':9C 'bend':41 'bind':53 'bottom':35 'bound':1A 'cannot':60 'crescent':3A,13 'elbow':43 'extend':19,45 'face':33 'gaze':69 'hand':27,36,47,52,55,59 'heart':65 'knee':7A,17 'lower':24 'lung':4A,14 'open':67 'palm':32 'parivrtta':8C 'parivṛtta':22 'reach':49,61 'revolv':2A,12 'shoulder':74 'strap':64 'thigh':40 'togeth':56 'top':26,73 'underneath':38 'use':62 'utthita':21 'wrap':37
179	Upward-Facing Dog	Ūrdhva Mukha Śvānāsana	Urdhva Mukha Svanasana	The body is in a prone position parallel to the earth.  The weight of the body is supported equally by the straight arms and the tops of the feet which press firmly into the earth.  The shoulders are rotated back and down.  The ribcage is lifted and pulled thru to the front in a slight upper thoracic backbend.  The joints are stacked with the wrists, elbows and shoulders in a straight-line.  The neck is a natural extension of the spine and the chin is slightly tucked.  The abdomen is pulled up towards the spine.  The palms are flat and the elbows are close to the side body.  The gaze is forward.	Intermediate	\N	Improves posture.  Strengthens the spine, arms, and wrists.  Stretches the chest, lungs, shoulders, and abdomen.  Firms the buttocks.  Stimulates abdominal organs.  Helps relieve mild depression, fatigue, and sciatica.  Therapeutic for asthma.	static/img/upward_dog.png	\N	Extended Child's,Downward-Facing Dog	Extended Child's,Four Limbed Staff	{"28": 1, "64": 3.5, "68": 1, "171": 1, "13": 1}	'abdomen':97 'arm':30 'back':47 'backbend':65 'bodi':9,23,116 'chin':92 'close':112 'dog':4A 'earth':18,42 'elbow':73,110 'equal':26 'extens':86 'face':3A 'feet':36 'firm':39 'flat':107 'forward':120 'front':59 'gaze':118 'joint':67 'lift':53 'line':80 'mukha':6C 'natur':85 'neck':82 'palm':105 'parallel':15 'posit':14 'press':38 'prone':13 'pull':55,99 'ribcag':51 'rotat':46 'shoulder':44,75 'side':115 'slight':62,94 'spine':89,103 'stack':69 'straight':29,79 'straight-lin':78 'support':25 'svanasana':7C 'thorac':64 'thru':56 'top':33 'toward':101 'tuck':95 'upper':63 'upward':2A 'upward-fac':1A 'urdhva':5C 'weight':20 'wrist':72
54	Crow	Bakāsana	Bakasana	From an inverted position, with the hips up and the head down, the arms are bent in a 90-degree angle with the knees resting on the elbows.  The palms are firmly rooted into the earth with knuckles pressed firmly into the earth for support.  The belly is pulled up and in towards the spine with the ribcage and chin lifted.  The weight of the body shifts slightly forward as the toes lift up and off the earth into the full expression of the pose.  The gaze is down and slightly forward.	Intermediate	\N	Strengthens arms and wrists.  Stretches the upper back.  Strengthens the abdominal muscles.  Opens the groin.  Tones the abdominal organs.	static/img/crow.png	\N	Crow (Preparation),One Legged Crow,Four Limbed Staff	Crow (Preparation),One Legged Crow	{"55": 1, "56": 1, "171": 1, "86": 1, "136": 1, "83": 1}	'90':21 'angl':23 'arm':16 'bakasana':2C 'belli':49 'bent':18 'bodi':68 'chin':62 'crow':1A 'degre':22 'earth':38,45,80 'elbow':30 'express':84 'firm':34,42 'forward':71,94 'full':83 'gaze':89 'head':13 'hip':9 'invert':5 'knee':26 'knuckl':40 'lift':63,75 'palm':32 'pose':87 'posit':6 'press':41 'pull':51 'rest':27 'ribcag':60 'root':35 'shift':69 'slight':70,93 'spine':57 'support':47 'toe':74 'toward':55 'weight':65
56	One Legged Crow	Eka Pāda Bakāsana	Eka Pada Bakasana	From Crow (Bakāsana), one leg lifts up and extends back as the chin lifts and reaches forward.  The gaze is down and slightly forward.	Expert	\N	Strengthens arms and wrists.  Stretches the upper back.  Strengthens the abdominal muscles.  Opens the groin.  Tones the abdominal organs.	static/img/crow_flying_L.png	t	Crow	Crow	{"54": 1, "136": 1, "83": 1, "64": 1}	'back':16 'bakasana':6C 'bakāsana':9 'chin':19 'crow':3A,8 'eka':4C 'extend':15 'forward':23,30 'gaze':25 'leg':2A,11 'lift':12,20 'one':1A,10 'pada':5C 'reach':22 'slight':29
55	Crow (Preparation)	\N	\N	The weight of the body is seated on the heels with the knees open, the arms extended straight and the palms of the hands are rooted into the earth between the thighs.  The belly is pulled up and in towards the spine with the ribcage and chin lifted.  The gaze is forward and slightly down.	Beginner	\N	Strengthens arms, wrists and ankles.  Stretches the upper back.  Strengthens the abdominal muscles.  Opens the groin.  Tones the abdominal organs.	static/img/seated_on_heels_hands_on_mat_opened_knees.png	\N	Crow,Plank	Crow,Squatting Toe Balance with Opened Knees	{"54": 1, "136": 1, "86": 1, "83": 1}	'arm':18 'belli':36 'bodi':7 'chin':49 'crow':1A 'earth':31 'extend':19 'forward':54 'gaze':52 'hand':26 'heel':12 'knee':15 'lift':50 'open':16 'palm':23 'prepar':2A 'pull':38 'ribcag':47 'root':28 'seat':9 'slight':56 'spine':44 'straight':20 'thigh':34 'toward':42 'weight':4
58	Side Crow (Preparation)	\N	\N	Start from Squatting Toe Balance pose with the palms flat on the floor and knees into the chest.  Keep the palms in place, turn the knees about 90 degrees to face one side, so the elbows are in front of the thigh.	Intermediate	\N	Strengthens the arms, biceps, triceps, shoulders, wrists and ankles.  Gently twist and strengthens the spine.	static/img/crow_side_preparation_L.png	t	Side Crow,Revolved Squatting Toe Balance	Side Crow,Revolved Squatting Toe Balance	{"57": 1, "167": 1, "168": 1, "165": 1}	'90':31 'balanc':8 'chest':21 'crow':2A 'degre':32 'elbow':39 'face':34 'flat':13 'floor':16 'front':42 'keep':22 'knee':18,29 'one':35 'palm':12,24 'place':26 'pose':9 'prepar':3A 'side':1A,36 'squat':6 'start':4 'thigh':45 'toe':7 'turn':27
59	Deaf Man's	Karṇapīḍāsana	Karnapidasana	From a supine position, the feet come over the head and rest on the earth with the knees next to the ears and the arms extended behind the body with the fingers interlaced.  The neck is flat on the earth.  The eyes are closed.  The gaze is inward.  Take three big gulps to stimulate the thyroid.	Expert	\N	Creates a deep release and internal balance.	static/img/deaf_man.png	\N	Corpse	Plow	{"32": 1, "144": 1, "153": 1, "154": 1}	'arm':28 'behind':30 'big':54 'bodi':32 'close':47 'come':10 'deaf':1A 'ear':25 'earth':18,43 'extend':29 'eye':45 'feet':9 'finger':35 'flat':40 'gaze':49 'gulp':55 'head':13 'interlac':36 'inward':51 'karnapidasana':3C 'knee':21 'man':2A 'neck':38 'next':22 'posit':7 'rest':15 'stimul':57 'supin':6 'take':52 'three':53 'thyroid':59
53	Crescent Moon	Ashta Chandrāsana	Ashta Chandrasana	From Mountain (Tāḍāsana) pose, on the inhalation bring the hands up and interlace the fingers together.  Exhale, bend to one side, lengthening the opposite of the rib cage and stretch.	Intermediate	\N	Stretches the rib cage, arms and torso.  Tones the oblique muscles.	static/img/crescent_moon_R.png	\N	\N	\N	{"131": 1, "130": 1, "83": 1, "91": 1}	'ashta':3C 'bend':22 'bring':12 'cage':32 'chandrasana':4C 'crescent':1A 'exhal':21 'finger':19 'hand':14 'inhal':11 'interlac':17 'lengthen':26 'moon':2A 'mountain':6 'one':24 'opposit':28 'pose':8 'rib':31 'side':25 'stretch':34 'togeth':20 'tāḍāsana':7
57	Side Crow	Pārśva Bakāsana	Parsva Bakasana	Start from Side Crow (Preparation) and lean forward.  Bend the elbows, placing the hips and knees on top of the arms.  Lift the chin up and look forward.  Shift more weight onto the arms and tip over, take one foot and then the other off the floor.	Expert	\N	Strengthens arms and wrists.  Improves balance.  Tones the abdominal muscles.	static/img/crow_side_L.png	t	Side Crow (Preparation)	Side Crow (Preparation)	{"58": 1, "136": 1, "171": 1, "80": 1, "64": 1}	'arm':25,38 'bakasana':4C 'bend':13 'chin':28 'crow':2A,8 'elbow':15 'floor':51 'foot':44 'forward':12,32 'hip':18 'knee':20 'lean':11 'lift':26 'look':31 'one':43 'onto':36 'parsva':3C 'place':16 'prepar':9 'shift':33 'side':1A,7 'start':5 'take':42 'tip':40 'top':22 'weight':35
39	Crescent Lunge Forward Bend	\N	\N	The foot of the front leg is rooted on the earth with the knee directly above and tracking the ankle in a 90 degree angle.  The back leg is straight, no bend in the knee, and the weight is distributed backwards onto the toes as the back heel pushes back and down towards the earth.  The inner thighs scissor towards each other and the pelvis is tucked under with the ribcage lifted and the chin slightly tucked. The spine is long and extended.  The lower body stays static.  The upper torso gently bends forward from the crease of the hip with a straight line.  The gaze is forward.	Intermediate	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, belly, groins (psoas) and the muscles of the back.  Strengthens and stretches the thighs, calves and ankles.	static/img/lunge_crescent_forward_bend_R.png	t	Crescent Lunge	Crescent Lunge	{"37": 1, "189": 1, "120": 1, "156": 1, "42": 1, "88": 1, "40": 1, "41": 1}	'90':27 'angl':29 'ankl':24 'back':31,51,54 'backward':45 'bend':4A,36,97 'bodi':90 'chin':79 'creas':101 'crescent':1A 'degre':28 'direct':19 'distribut':44 'earth':15,59 'extend':87 'foot':6 'forward':3A,98,112 'front':9 'gaze':110 'gentl':96 'heel':52 'hip':104 'inner':61 'knee':18,39 'leg':10,32 'lift':76 'line':108 'long':85 'lower':89 'lung':2A 'onto':46 'pelvi':69 'push':53 'ribcag':75 'root':12 'scissor':63 'slight':80 'spine':83 'static':92 'stay':91 'straight':34,107 'thigh':62 'toe':48 'torso':95 'toward':57,64 'track':22 'tuck':71,81 'upper':94 'weight':42
62	Dolphin Plank	\N	\N	From a prone position the weight of the body is distributed equally between the toes of flexed feet and strong forearms pressed firmly into the earth.  The shoulders are directly over the wrists, the torso is parallel to the floor.  The outer arms are pressed inward and are firm.  The bases of the index fingers are pressed into the earth.  The shoulder blades are firmly spread away from the spine.  The collarbones are away from the sternum.  The front thighs press up towards the sky, while the tailbone resists and pulls towards the earth, lengthening towards the heels.  The base of the skull lifts away from the back of the neck and the gaze is soft and down.	Intermediate	\N	Strengthens the arms, wrists, and spine.  Tones the abdomen.	static/img/plank_dolphin.png	\N	Side Dolphin Plank	Side Dolphin Plank	{"63": 1, "60": 1, "61": 1, "136": 1}	'arm':45 'away':69,76,107 'back':110 'base':53,102 'blade':65 'bodi':11 'collarbon':74 'direct':32 'distribut':13 'dolphin':1A 'earth':28,62,96 'equal':14 'feet':20 'finger':57 'firm':25,51,67 'flex':19 'floor':42 'forearm':23 'front':81 'gaze':116 'heel':100 'index':56 'inward':48 'lengthen':97 'lift':106 'neck':113 'outer':44 'parallel':39 'plank':2A 'posit':6 'press':24,47,59,83 'prone':5 'pull':93 'resist':91 'shoulder':30,64 'skull':105 'sky':87 'soft':118 'spine':72 'spread':68 'sternum':79 'strong':22 'tailbon':90 'thigh':82 'toe':17 'torso':37 'toward':85,94,98 'weight':8 'wrist':35
69	Downward-Facing Dog with Toe Raises	\N	\N	From Downward-Facing Dog (Adho Mukha Śvānāsana), the weight of the body is supported on the hands and the toes.  The ribcage is lifted.  The shoulder blades rotate back and open.  The heart is open.  The gaze is to the front and slightly down.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.  Warms up the ankles and the toes.	static/img/downward_dog_on_toes.png	\N	Downward-Facing Dog,Downward-Facing Dog with Hamstring Stretch	Downward-Facing Dog,Downward-Facing Dog with Hamstring Stretch	{"64": 1, "66": 1, "70": 1, "68": 1}	'adho':13 'back':37 'blade':35 'bodi':20 'dog':4A,12 'downward':2A,10 'downward-fac':1A,9 'face':3A,11 'front':49 'gaze':45 'hand':25 'heart':41 'lift':32 'mukha':14 'open':39,43 'rais':7A 'ribcag':30 'rotat':36 'shoulder':34 'slight':51 'support':22 'toe':6A,28 'weight':17 'śvānāsana':15
132	Feathered Peacock	Pīñcha Mayūrāsana	Pincha Mayurasana	From an inverted position, with the body perpendicular to the earth, the weight of the body is supported on the forearms that are parallel and pressed firmly into the earth.  The palms are flat.  The knuckles are evenly pressed into the earth.  The fingers are spread wide.  Both legs reach up toward the sky in a straight line with the pelvis tucked.  The ribcage is lifted.  The gaze is forward.	Expert	\N	Strengthens arms and shoulders.  Improves focus and balance.  Stretches the upper and lower back.  Strengthens the abdominal muscles.  Tones the abdominal area.	static/img/feathered_peacock.png	\N	Dolphin,Scorpion	Dolphin,Scorpion	{"60": 1, "151": 1, "61": 1, "62": 1}	'bodi':11,20 'earth':15,34,46 'even':42 'feather':1A 'finger':48 'firm':31 'flat':38 'forearm':25 'forward':74 'gaze':72 'invert':7 'knuckl':40 'leg':53 'lift':70 'line':62 'mayurasana':4C 'palm':36 'parallel':28 'peacock':2A 'pelvi':65 'perpendicular':12 'pincha':3C 'posit':8 'press':30,43 'reach':54 'ribcag':68 'sky':58 'spread':50 'straight':61 'support':22 'toward':56 'tuck':66 'weight':17 'wide':51
61	One Legged Dolphin	\N	\N	From Downward-Facing Dog (Adho Mukha Śvānāsana), the forearms are planted onto the earth with the elbows narrow and the palms flat in a Sphinx (Sālamba Bhujaṅgāsana) position.  The pelvis is tucked.  The ribcage lifted.  One leg is straight and rooted to the earth, while the other reaches straight towards the sky.  The gaze is down and slightly forward.	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.  Warms up the ankles and the toes.	static/img/dolphin_leg_up_R.png	t	Dolphin	Dolphin	{"60": 1, "62": 1, "70": 1, "132": 1}	'adho':9 'bhujaṅgāsana':31 'dog':8 'dolphin':3A 'downward':6 'downward-fac':5 'earth':18,48 'elbow':21 'face':7 'flat':26 'forearm':13 'forward':63 'gaze':58 'leg':2A,41 'lift':39 'mukha':10 'narrow':22 'one':1A,40 'onto':16 'palm':25 'pelvi':34 'plant':15 'posit':32 'reach':52 'ribcag':38 'root':45 'sky':56 'slight':62 'sphinx':29 'straight':43,53 'sālamba':30 'toward':54 'tuck':36 'śvānāsana':11
68	Downward-Facing Dog with Stacked Hips	\N	\N	From Downward-Facing Dog (Adho Mukha Śvānāsana), one leg reaches up toward the sky, the top knee is bent and the hips are stacked.  The shoulders are squared to the earth.  Heart is open.  The shoulder blades squeeze together and the forehead drops down towards the earth.  The gaze is to the back.	Intermediate	\N	Tones and strengthens the standing leg.  Improves flexibility.  Opens the hips.	static/img/downward_dog_leg_up_stack_hips_R.png	t	One Legged Downward-Facing Dog,Wild Thing	One Legged Downward-Facing Dog	{"70": 1, "192": 1, "67": 1}	'adho':13 'back':61 'bent':27 'blade':45 'dog':4A,12 'downward':2A,10 'downward-fac':1A,9 'drop':51 'earth':39,55 'face':3A,11 'forehead':50 'gaze':57 'heart':40 'hip':7A,30 'knee':25 'leg':17 'mukha':14 'one':16 'open':42 'reach':18 'shoulder':34,44 'sky':22 'squar':36 'squeez':46 'stack':6A,32 'togeth':47 'top':24 'toward':20,53 'śvānāsana':15
48	Revolved Crescent Lunge on the Knee	Parivṛtta Aṅjaneyāsana	Parivrtta Anjaneyasana	From Crescent Lunge on the Knee with Prayer Hands, slowly twist the spine to one side, hooking the elbow outside of the knee.  Stack the shoulders on top of each other, keep the heart open and gaze up towards the sky.	Intermediate	\N	Lengthens and stretches the spine.  Creates flexibility in the rib cage.  Stimulates the internal abdominal organs and kidneys.	static/img/lunge_kneeling_twist_R.png	t	Crescent Lunge on the Knee with Prayer Hands,Revolved Crescent Lunge on the Knee with Extended Arms	Crescent Lunge on the Knee with Prayer Hands,Revolved Crescent Lunge on the Knee with Extended Arms	{"46": 1, "49": 1, "40": 1, "45": 1, "124": 1, "123": 1}	'anjaneyasana':8C 'crescent':2A,10 'elbow':27 'gaze':45 'hand':17 'heart':42 'hook':25 'keep':40 'knee':6A,14,31 'lung':3A,11 'one':23 'open':43 'outsid':28 'parivrtta':7C 'prayer':16 'revolv':1A 'shoulder':34 'side':24 'sky':49 'slowli':18 'spine':21 'stack':32 'top':36 'toward':47 'twist':19
66	Downward-Facing Dog with Hamstring Stretch	\N	\N	From Downward-Facing Dog (Adho Mukha Śvānāsana), one knee is bent and one leg is straight with the sits bones tilted up and reaching for the sky.  The arms are straight with the eye of the elbows facing forward.  The palms are flat.  The knuckles are pressed evenly into the earth.  The heels alternatively lift and lower with the weight of the body equally distributed between the hands and the feet.  The ribcage is lifted and the heart is open.  Shoulders are squared, rotated back, down and inward.  The chin is lifted and the gaze is down and slightly forward.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.  Warms up the ankles, toes, knees and hamstrings.	static/img/downward_dog_hamstring_R.png	\N	Downward-Facing Dog with Toe Raises	Downward-Facing Dog with Toe Raises	{"69": 1, "65": 1, "64": 1, "67": 1, "68": 1, "71": 1, "91": 1, "83": 1, "70": 1, "136": 1}	'adho':13 'altern':62 'arm':37 'back':93 'bent':19 'bodi':71 'bone':28 'chin':98 'distribut':73 'dog':4A,12 'downward':2A,10 'downward-fac':1A,9 'earth':59 'elbow':45 'equal':72 'even':56 'eye':42 'face':3A,11,46 'feet':79 'flat':51 'forward':47,108 'gaze':103 'hamstr':6A 'hand':76 'heart':86 'heel':61 'inward':96 'knee':17 'knuckl':53 'leg':22 'lift':63,83,100 'lower':65 'mukha':14 'one':16,21 'open':88 'palm':49 'press':55 'reach':32 'ribcag':81 'rotat':92 'shoulder':89 'sit':27 'sky':35 'slight':107 'squar':91 'straight':24,39 'stretch':7A 'tilt':29 'weight':68 'śvānāsana':15
37	Crescent Lunge	\N	\N	The front foot of one leg is rooted on the earth with the knee directly above and tracking the ankle in a 90 degree angle.  The back leg is straight, no bend in the knee, and the weight is distributed backwards onto the toes as the back heel pushes back and down towards the earth.  The inner thighs scissor towards each other and the pelvis is tucked under with the ribcage lifted and the chin slightly tucked.  The spine is long and extended.  The heart is open.  The arms are straight with no bend in the elbows or the wrists.  The hands can be together or separated and facing each other with the fingers spread wide.  Gaze is natural and forward.	Intermediate	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, belly, groins (psoas) and the muscles of the back.  Strengthens and stretches the thighs, calves and ankles.	static/img/lunge_crescent_R.png	t	Crescent Lunge with Prayer Hands,Crescent Lunge Forward Bend,Crescent Lunge Twist,Lunge,Lunge on the Knee,Pyramid,Warrior III	Crescent Lunge with Prayer Hands,Crescent Lunge Forward Bend,Crescent Lunge Twist,Lunge,Pyramid,Warrior III	{"38": 1, "39": 1, "43": 1, "120": 1, "124": 1, "145": 1, "189": 1, "64": 1, "91": 1, "182": 1, "107": 1, "88": 1, "45": 1}	'90':25 'angl':27 'ankl':22 'arm':91 'back':29,49,52 'backward':43 'bend':34,96 'chin':77 'crescent':1A 'degre':26 'direct':17 'distribut':42 'earth':13,57 'elbow':99 'extend':85 'face':111 'finger':116 'foot':5 'forward':123 'front':4 'gaze':119 'hand':104 'heart':87 'heel':50 'inner':59 'knee':16,37 'leg':8,30 'lift':74 'long':83 'lung':2A 'natur':121 'one':7 'onto':44 'open':89 'pelvi':67 'push':51 'ribcag':73 'root':10 'scissor':61 'separ':109 'slight':78 'spine':81 'spread':117 'straight':32,93 'thigh':60 'toe':46 'togeth':107 'toward':55,62 'track':20 'tuck':69,79 'weight':40 'wide':118 'wrist':102
41	Revolved Crescent Lunge with Extended Arms	Utthita Parivṛtta Aṅjaneyāsana	Utthita Parivrtta Anjaneyasana	From Revolved Crescent Lunge (Parivṛtta Aṅjaneyāsana), slowly release the hands and extend both arms.  Bottom hand can touch the floor or float.  A block may be used for support when needed.  Top hand reaches up towards the sky.  Keep both hands straight and the heart remains open.  Gaze is upward towards the top hand.	Intermediate	\N	Lengthens and stretches the spine.  Creates flexibility in the rib cage.  Stimulates the internal abdominal organs and kidneys.  Opens the shoulders and strengthens the back muscles.	static/img/lunge_twist_extended_R.png	t	Revolved Crescent Lunge,Bound Revolved Crescent Lunge	Revolved Crescent Lunge,Bound Revolved Crescent Lunge	{"40": 1, "42": 1, "38": 1, "37": 1, "24": 1, "25": 1}	'anjaneyasana':9C 'arm':6A,23 'aṅjaneyāsana':15 'block':33 'bottom':24 'crescent':2A,12 'extend':5A,21 'float':31 'floor':29 'gaze':57 'hand':19,25,42,50,63 'heart':54 'keep':48 'lung':3A,13 'may':34 'need':40 'open':56 'parivrtta':8C 'parivṛtta':14 'reach':43 'releas':17 'remain':55 'revolv':1A,11 'sky':47 'slowli':16 'straight':51 'support':38 'top':41,62 'touch':27 'toward':45,60 'upward':59 'use':36 'utthita':7C
133	Pigeon	Kapotāsana	Kapotasana	The body is in an arched supine position with the hips and the ribcage lifted, the knees and the elbows are bent, the forearms and the shins are supporting the weight of the body and the crown of the head is softly resting on the earth.  The palms are either resting on the feet or are hooked around the heels (depending on flexibility).  The weight of the body is distributed equally between the forearms and the shins as the pelvis presses up and the ribcage lifts.  The tailbone lengthens towards the knees and the sternum lifts up in the opposite direction creating a gentle arch in the back of the body.  The gaze is out in front or down to the earth, depending on flexibility.	Expert	\N	Stretches the entire front of the body, the ankles, thighs and groins, abdomen and chest, and throat.  Stretches the deep hip flexors (psoas).  Strengthens the back muscles.  Improves posture.  Stimulates the organs of the abdomen and neck.	static/img/pigeon.png	\N	Camel	Camel	{"19": 1, "109": 1, "108": 1, "32": 1}	'arch':8,107 'around':60 'back':110 'bent':24 'bodi':4,36,70,113 'creat':104 'crown':39 'depend':63,125 'direct':103 'distribut':72 'earth':48,124 'either':52 'elbow':22 'equal':73 'feet':56 'flexibl':65,127 'forearm':26,76 'front':119 'gaze':115 'gentl':106 'head':42 'heel':62 'hip':13 'hook':59 'kapotasana':2C 'knee':19,94 'lengthen':91 'lift':17,88,98 'opposit':102 'palm':50 'pelvi':82 'pigeon':1A 'posit':10 'press':83 'rest':45,53 'ribcag':16,87 'shin':29,79 'soft':44 'sternum':97 'supin':9 'support':31 'tailbon':90 'toward':92 'weight':33,67
73	Easy	Sukhāsana	Sukhasana	From a seated position, bring your knees into a simple cross legged pose.  Both knees should be below the hips.  Place the hands on the thighs or knees and keep the spine straight.	Beginner	\N	Opens the hips and stretches the knees and ankles.  Strengthens the back.  Calms the mind, reduces stress and anxiety.  Improves circulation and blood flow to the pelvis.	static/img/easy.png	\N	\N	\N	{"6": 1, "7": 1, "8": 1, "13": 1.5, "21": 1, "35": 1, "36": 1, "74": 1, "76": 1, "81": 1, "107": 1, "130": 1, "163": 1, "169": 1}	'bring':7 'cross':13 'easi':1A 'hand':25 'hip':22 'keep':32 'knee':9,17,30 'leg':14 'place':23 'pose':15 'posit':6 'seat':5 'simpl':12 'spine':34 'straight':35 'sukhasana':2C 'thigh':28
72	Eagle	Garuḍāsana	Garudasana	From a standing position the one thigh is crossed over the other with the toes and/or the ankle hooked behind the lower calf.  The weight of the body is balanced on the standing foot.  The arms are crossed in front of the torso so that one arm is crossed above the other arm.  The top arm is tucked into the elbow crook of the bottom arm.  The hands are hooked around each other as well.  Once hooked, the elbows lift up and the fingers stretch towards the ceiling.  The gaze is soft and forward.	Intermediate	\N	Strengthens and stretches the ankles and calves.  Stretches the thighs, hips, shoulders, and upper back.  Improves concentration.  Improves sense of balance.	static/img/eagle_L.png	t	Mountain	Mountain	{"130": 1, "175": 1, "6": 1, "17": 1, "136": 1, "22": 1, "131": 1, "1": 1, "23": 1}	'and/or':18 'ankl':20 'arm':38,49,55,58,68 'around':73 'balanc':32 'behind':22 'bodi':30 'bottom':67 'calf':25 'ceil':90 'crook':64 'cross':11,40,51 'eagl':1A 'elbow':63,81 'finger':86 'foot':36 'forward':96 'front':42 'garudasana':2C 'gaze':92 'hand':70 'hook':21,72,79 'lift':82 'lower':24 'one':8,48 'posit':6 'soft':94 'stand':5,35 'stretch':87 'thigh':9 'toe':17 'top':57 'torso':45 'toward':88 'tuck':60 'weight':27 'well':77
47	Crescent Lunge Forward Bend on the Knee	\N	\N	The front knee is bent in a 90-degree angle directly above the ankle and the back knee is resting on the earth with the top of the back foot pressed firmly into the earth.  The hips are squared and pressed forward.  The inner thighs are scissored towards each other.  The pelvis is tucked under to protect the low back.  The ribcage is lifted.  The arms are lifted.  The hands can be together or separated and facing each other with the fingers spread wide.  The lower body stays static.  The upper torso gently bends forward from the crease of the hip with a straight line.  The gaze is forward.	Beginner	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, belly, groins (psoas) and the muscles of the back.  Strengthens and stretches the thighs, calves and ankles.	static/img/lunge_crescent_kneeling_forward_bend_R.png	t	Crescent Lunge on the Knee	Crescent Lunge on the Knee	{"45": 1, "120": 1, "124": 1}	'90':15 'angl':17 'ankl':21 'arm':73 'back':24,36,67 'bend':4A,101 'bent':12 'bodi':94 'creas':105 'crescent':1A 'degre':16 'direct':18 'earth':30,42 'face':84 'finger':89 'firm':39 'foot':37 'forward':3A,49,102,116 'front':9 'gaze':114 'gentl':100 'hand':77 'hip':44,108 'inner':51 'knee':7A,10,25 'lift':71,75 'line':112 'low':66 'lower':93 'lung':2A 'pelvi':59 'press':38,48 'protect':64 'rest':27 'ribcag':69 'scissor':54 'separ':82 'spread':90 'squar':46 'static':96 'stay':95 'straight':111 'thigh':52 'togeth':80 'top':33 'torso':99 'toward':55 'tuck':61 'upper':98 'wide':91
79	Flying Man	Eka Pāda Kouṇḍinyāsana	Eka Pada Koundinyasana	From a lunge position, the palms are rooted into the earth on the inside of the thigh.  Both elbows are bent in a 90-degree angle with one leg forward, extended and resting softly on the elbow.  The other leg is extended back either balanced on the toes or suspended in flight with active toes.  The Body is parallel to the earth.  The gaze is to the front.	Expert	\N	Strengthens arms, legs, core and wrists.  Improves balance.	static/img/lunge_hands_on_mat_flying_L.png	t	One Legged Downward-Facing Dog,Eight Angle,Four Limbed Staff	One Legged Downward-Facing Dog,Eight Angle,Handstand,Lunge with Hands on the Inside of the Leg	{"70": 1, "74": 1, "171": 1, "136": 1}	'90':29 'activ':59 'angl':31 'back':48 'balanc':50 'bent':26 'bodi':62 'degre':30 'earth':16,67 'either':49 'eka':3C 'elbow':24,42 'extend':36,47 'fli':1A 'flight':57 'forward':35 'front':73 'gaze':69 'insid':19 'koundinyasana':5C 'leg':34,45 'lung':8 'man':2A 'one':33 'pada':4C 'palm':11 'parallel':64 'posit':9 'rest':38 'root':13 'soft':39 'suspend':55 'thigh':22 'toe':53,60
136	Plank	Phalakāsana	Phalakasana	The body is parallel to the earth.  The weight of the body is supported by straight arms and active toes.  The abdomen is pulled up towards the spine and the pelvis is tucked in.  The neck is a natural extension of the spine and the chin is slightly tucked.  The palms are flat and the elbows are close to the side body.  The joints are stacked with the wrists, elbows and shoulders in a straight line perpendicular to the earth.  The gaze follows the spine and the eyes are focused down.	Intermediate	\N	Strengthens the arms, wrists, and spine.  Tones the abdomen.	static/img/plank.png	\N	Box,Extended Child's,Front Corpse,Downward-Facing Dog,Side Plank,Side Plank on the Knee,Four Limbed Staff	Front Corpse,Crow (Preparation),Downward-Facing Dog,Halfway Lift,Side Plank,Warrior II	{"13": 1, "28": 1, "33": 1, "64": 1, "138": 2.0, "142": 1, "171": 2.0, "120": 1, "31": 1, "62": 1, "143": 1, "137": 1, "83": 1, "67": 1}	'abdomen':24 'activ':21 'arm':19 'bodi':4,14,64 'chin':48 'close':60 'earth':9,82 'elbow':58,72 'extens':42 'eye':90 'flat':55 'focus':92 'follow':85 'gaze':84 'joint':66 'line':78 'natur':41 'neck':38 'palm':53 'parallel':6 'pelvi':33 'perpendicular':79 'phalakasana':2C 'plank':1A 'pull':26 'shoulder':74 'side':63 'slight':50 'spine':30,45,87 'stack':68 'straight':18,77 'support':16 'toe':22 'toward':28 'tuck':35,51 'weight':11 'wrist':71
77	Firefly	Tittibhāsana	Tittibhasana	The arms are straight and the palms are pressed into the earth.  The body is supported on the straight arms with the eye of the elbows to the front.  The legs are extended straight and forward from on the outside of the arms.  The ribcage is lifted.  The gaze is forward.	Expert	\N	Strengthens arms and wrists.  Improves focus and concentration.  Opens flexibility of lower body.	static/img/firefly.png	\N	Side Splits	Scale	{"163": 1, "86": 1, "174": 1}	'arm':4,22,45 'bodi':16 'earth':14 'elbow':28 'extend':35 'eye':25 'firefli':1A 'forward':38,53 'front':31 'gaze':51 'leg':33 'lift':49 'outsid':42 'palm':9 'press':11 'ribcag':47 'straight':6,21,36 'support':18 'tittibhasana':2C
76	Fire Log	Agnistambhāsana	Agnistambhasana	From a seated position, stack both shins on top of each other until they are parallel to the front edge of the mat.	Beginner	\N	Opens the hips.  Strengthens the back muscles by elongating the spine.  Improves alignment of the spine; thereby improving posture.  Calming and centering pose that improves concentration and facilitates meditation.  Ameliorates stress and anxiety.	static/img/fire_log_R.png	t	\N	\N	{"8": 1, "21": 1, "35": 1, "36": 1, "7": 1, "6": 1, "119": 1, "129": 1, "81": 1, "169": 1}	'agnistambhasana':3C 'edg':23 'fire':1A 'front':22 'log':2A 'mat':26 'parallel':19 'posit':7 'seat':6 'shin':10 'stack':8 'top':12
111	One Legged King Pigeon (Preparation)	\N	\N	From a lounging position, the hips are parallel and squared to the earth with the front knee bent in a 90-degree angle and flat on the earth.  The front foot rests close to the groin.  The back leg is extended with the knee and the back foot squared, parallel and pressed firmly into the earth.  The ribcage is lifted.  The heart is open.  Fingers rest on the earth by the side body.  The gaze is forward.	Beginner	\N	Stretches the thighs, groin, psoas, abdomen, chest, shoulders, and neck.  Stimulates the abdominal organs.  Opens the shoulders and chest.	static/img/pigeon_half_R.png	t	Cow Face (Preparation),One Legged Downward-Facing Dog,One Legged King Pigeon - Mermaid,Sleeping Swan,Front Splits	Box,One Legged Downward-Facing Dog,Sleeping Swan	{"36": 1, "70": 1, "112": 1, "159": 1, "162": 1, "89": 1, "72": 1, "64": 1, "13": 1}	'90':26 'angl':28 'back':43,52 'bent':23 'bodi':78 'close':38 'degre':27 'earth':18,33,61,74 'extend':46 'finger':70 'firm':58 'flat':30 'foot':36,53 'forward':82 'front':21,35 'gaze':80 'groin':41 'heart':67 'hip':11 'king':3A 'knee':22,49 'leg':2A,44 'lift':65 'loung':8 'one':1A 'open':69 'parallel':13,55 'pigeon':4A 'posit':9 'prepar':5A 'press':57 'rest':37,71 'ribcag':63 'side':77 'squar':15,54
87	Gorilla	Pādahastāsana	Padahastasana	Begin from an upright standing position with the feet parallel (about six inches apart) and the front of the thighs contracted to lift the kneecaps.  The body is bent forward from the crease of the hip joints with the legs completely straight and the torso parallel to the earth.  The index and middle fingers of each hand are wrapped between the big toes and the second toes.  Fingers and thumbs are curled around and under the big toes to firmly secure the wrap.  The toes press down against the fingers.  To fold deeper into the pose the sitting bones are lifted up towards the sky, the torso is pressed towards the thighs and the crown of the head is lowered towards the earth.  Depending on flexibility, the lower back hollows to a greater or lesser degree.  At the same time, without compressing the back of the neck, the sternum is lifted.  The forehead stays relaxed.  For the full extension of the pose the elbows bend out to the sides as the toes are pulled up.  This lengthens the front and sides of the torso.  For very long hamstrings, draw the forehead toward the shins.  For hamstrings that are short, it is better to focus on keeping the front torso long.  The gaze is down or towards the body.	Intermediate	\N	Calms the brain and helps relieve stress and anxiety.  Stimulates the liver and the kidneys.  Stretches the hamstrings and the calves.  Strengthens the thighs.  Improves digestion.  Helps relieve the symptoms of menopause.  Helps relieve headaches and insomnia.	static/img/gorilla.png	\N	\N	Halfway Lift	{"83": 1, "91": 1}	'apart':16 'around':75 'back':131,146 'begin':3 'bend':167 'bent':31 'better':204 'big':64,79 'bodi':29,220 'bone':101 'complet':43 'compress':144 'contract':23 'creas':35 'crown':117 'curl':74 'deeper':95 'degre':138 'depend':126 'draw':191 'earth':51,125 'elbow':166 'extens':161 'feet':11 'finger':56,70,92 'firm':82 'flexibl':128 'focus':206 'fold':94 'forehead':155,193 'forward':32 'front':19,181,210 'full':160 'gaze':214 'gorilla':1A 'greater':135 'hamstr':190,198 'hand':59 'head':120 'hip':38 'hollow':132 'inch':15 'index':53 'joint':39 'keep':208 'kneecap':27 'leg':42 'lengthen':179 'lesser':137 'lift':25,103,153 'long':189,212 'lower':122,130 'middl':55 'neck':149 'padahastasana':2C 'parallel':12,48 'pose':98,164 'posit':8 'press':88,111 'pull':176 'relax':157 'second':68 'secur':83 'shin':196 'short':201 'side':171,183 'sit':100 'six':14 'sky':107 'stand':7 'stay':156 'sternum':151 'straight':44 'thigh':22,114 'thumb':72 'time':142 'toe':65,69,80,87,174 'torso':47,109,186,211 'toward':105,112,123,194,218 'upright':6 'without':143 'wrap':61,85
85	Frog	Bhekāsana	Bhekasana	Begin from Wide Child's (Balāsana) pose.  Bring the hips and slide both hands forward at the same time, chest and forehead on the ground.  Hips can start high and then start to bring the hip in line with the knees.  Separate the feet as wide as the knees.	Intermediate	\N	Deep opener for the groin.  Mildly compresses the lower back and stimulates the spine.	static/img/frog.png	\N	\N	\N	{"29": 1, "28": 1, "13": 1, "64": 1}	'balāsana':8 'begin':3 'bhekasana':2C 'bring':10,36 'chest':22 'child':6 'feet':46 'forehead':24 'forward':17 'frog':1A 'ground':27 'hand':16 'high':31 'hip':12,28,38 'knee':43,51 'line':40 'pose':9 'separ':44 'slide':14 'start':30,34 'time':21 'wide':5,48
91	Halfway Lift	Ardha Uttānāsana	Ardha Uttanasana	From a standing position, the upper body is lifted up halfway with the feet rooted into the earth and the toes actively lifted.  The spine is straight.  The ribcage is lifted and connected to the thighs.  The neck is a natural extension of the spine.  The fingertips are next to the toes.  The gaze is down and slightly forward.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the liver and kidneys.  Stretches the hamstrings, calves, and hips.  Strengthens the thighs and knees.  Improves digestion.  Helps relieve the symptoms of menopause.  Reduces fatigue and anxiety.  Relieves headache and insomnia.	static/img/forward_bend_half_way.png	\N	Standing Forward Bend,Standing Forward Bend with Shoulder Opener,Gorilla,Lunge,Lunge on the Knee,Plank,Plank on the Knees,Squatting Toe Balance,Four Limbed Staff	Downward-Facing Dog,Standing Forward Bend,Standing Forward Bend with Shoulder Opener	{"37": 1, "83": 2, "84": 1, "87": 1, "120": 1, "124": 1, "136": 2, "143": 1, "165": 1, "171": 2}	'activ':26 'ardha':3C 'bodi':11 'connect':37 'earth':22 'extens':46 'feet':18 'fingertip':51 'forward':63 'gaze':58 'halfway':1A,15 'lift':2A,13,27,35 'natur':45 'neck':42 'next':53 'posit':8 'ribcag':33 'root':19 'slight':62 'spine':29,49 'stand':7 'straight':31 'thigh':40 'toe':25,56 'upper':10 'uttanasana':4C
145	Pyramid	Pārśvottānāsana	Parsvottanasana	From a standing position with one leg forward and one back lean the torso forward at the crease of the hip joint.  Stop when the torso is parallel to the floor.  Press the fingertips or flat palms to the floor on either side of the front foot, maintaining a straight elongated spine.  If it isn’t possible to touch the floor, or to maintain a straight spine, support the hands on a pair of blocks.  Press the thighs back and lengthen the torso forward, lifting up through the top of the sternum.  Then, as flexibility allows, bring the front torso closer to the top of the thigh without rounding the spine.  Eventually the long front torso will rest down on the thigh.  The gaze is down.	Intermediate	\N	Calms the brain.  Stretches the spine, the shoulders, the hips and the hamstrings.  Strengthens the legs.  Stimulates the abdominal organs.  Improves posture and sense of balance.  Improves digestion.	static/img/pyramid_R.png	t	Crescent Lunge,Lunge	Crescent Lunge,Lunge	{"37": 1, "120": 1, "176": 1, "146": 1, "83": 1}	'allow':98 'back':13,81 'block':77 'bring':99 'closer':103 'creas':20 'either':44 'elong':53 'eventu':114 'fingertip':36 'flat':38 'flexibl':97 'floor':33,42,63 'foot':49 'forward':10,17,86 'front':48,101,117 'gaze':126 'hand':72 'hip':23 'isn':57 'joint':24 'lean':14 'leg':9 'lengthen':83 'lift':87 'long':116 'maintain':50,66 'one':8,12 'pair':75 'palm':39 'parallel':30 'parsvottanasana':2C 'posit':6 'possibl':59 'press':34,78 'pyramid':1A 'rest':120 'round':111 'side':45 'spine':54,69,113 'stand':5 'sternum':94 'stop':25 'straight':52,68 'support':70 'thigh':80,109,124 'top':91,106 'torso':16,28,85,102,118 'touch':61 'without':110
89	Bound Half Moon	Baddha Ardha Chandrāsana	Baddha Ardha Chandrasana	From a standing position one leg is straight while the other is extended back parallel to the earth (or a little above parallel) and one hand is on the earth (beyond the little-toe side of the foot, about 12 inches) while the other hand reaches back to grasp the outside of the foot or ankle of the raised leg.  The shoulder blades are squeezed together.  The weight of the body is supported mostly by the standing leg while the bottom hand has very little weight on it but is used perceptively to maintain balance.  The upper torso is rotated open to the sky.  Both hips are externally rotated.  Energy is extended actively through the flexed toes to keep the raised leg strong.  The inner ankle of the standing foot is lifted strongly upward, as if drawing energy from the earth.  The sacrum and scapulae are firmly pressed against the back torso and lengthen the coccyx toward the raised leg.  The gaze is either up or down, depending on the condition of the neck.  If the neck is injured, the gaze is down.	Expert	\N	Strengthens the abdomen, ankles, thighs, buttocks and spine.  Stretches the groins, hamstrings, calves, shoulders, chest and spine.  Improves coordination and sense of balance.  Helps relieve stress.  Improves digestion.  Increases circulation.	static/img/half_moon_bound_R.png	t	Half Moon	Half Moon	{"88": 1, "90": 1, "116": 1, "164": 1, "83": 1, "64": 1}	'12':47 'activ':120 'ankl':63,133 'ardha':5C 'back':20,54,158 'baddha':4C 'balanc':102 'beyond':37 'blade':70 'bodi':78 'bottom':88 'bound':1A 'chandrasana':6C 'coccyx':163 'condit':178 'depend':175 'draw':144 'earth':24,36,148 'either':171 'energi':117,145 'extend':19,119 'extern':115 'firm':154 'flex':123 'foot':45,61,137 'gaze':169,188 'grasp':56 'half':2A 'hand':32,52,89 'hip':113 'inch':48 'injur':186 'inner':132 'keep':126 'leg':12,67,85,129,167 'lengthen':161 'lift':139 'littl':27,40,92 'little-to':39 'maintain':101 'moon':3A 'most':81 'neck':181,184 'one':11,31 'open':108 'outsid':58 'parallel':21,29 'percept':99 'posit':10 'press':155 'rais':66,128,166 'reach':53 'rotat':107,116 'sacrum':150 'scapula':152 'shoulder':69 'side':42 'sky':111 'squeez':72 'stand':9,84,136 'straight':14 'strong':130,140 'support':80 'toe':41,124 'togeth':73 'torso':105,159 'toward':164 'upper':104 'upward':141 'use':98 'weight':75,93
93	Extended Standing Hand to Toe	Utthita Hasta Pādāṅguṣṭhāsana	Utthita Hasta Padangusthasana	From Mountain (Tāḍāsana) pose, lift one foot.  Bend forward and catch the toes with the fingers.  Place the other hand on the hip to square the hip towards the front.  Slowly straighten the knee and the torso and open the leg to one side.  Use a strap if necessary.  Gaze towards the front or opposite of the extended leg for balance.	Expert	\N	Opens the hips and groins.  Stretches the hamstrings, IT bands and legs.  Improves balance.	static/img/standing_hand_to_toe_extended_R.png	t	Standing Hand to Toe,Mountain	Standing Hand to Toe	{"92": 1, "130": 1, "113": 1}	'balanc':69 'bend':16 'catch':19 'extend':1A,66 'finger':24 'foot':15 'forward':17 'front':38,61 'gaze':58 'hand':3A,28 'hasta':7C 'hip':31,35 'knee':42 'leg':49,67 'lift':13 'mountain':10 'necessari':57 'one':14,51 'open':47 'opposit':63 'padangusthasana':8C 'place':25 'pose':12 'side':52 'slowli':39 'squar':33 'stand':2A 'straighten':40 'strap':55 'toe':5A,21 'torso':45 'toward':36,59 'tāḍāsana':11 'use':53 'utthita':6C
148	Rabbit	Sasangāsana	Sasangasana	From Child's (Balāsana) pose, rest the torso onto the thighs and the forehead onto the earth.  Walk the knees up to meet the forehead, shifting some weight to the crown of the head.  Find the maximum comfortable neck stretch and then reach back and grip the base of the feet (use a strap if necessary).  To increase the stretch and come into the full expression of the pose, gradually lift or elevate your hips.  Be sure to keep your forehead as close as possible to your knees and the topmost part of your skull (crown of the head) on the earth.  Contract your abdominal muscles and gaze at your ankles.	Beginner	\N	Maintains the mobility and elasticity of spine.  Nurtures the nervous system and helps with depression.  Improves digestion.  Helps cure sinus problems, colds and chronic tonsillitis.  Strengthens and firms the abdomen.  Stretches the back muscles.  Removes the tension from the upper back and the neck.  Improves posture.  Stimulates the thymus gland, improving the function of the immune system.	static/img/rabbit.png	\N	\N	\N	{"13": 1, "28": 1, "27": 1}	'abdomin':107 'ankl':113 'back':46 'balāsana':6 'base':50 'child':4 'close':85 'come':64 'comfort':40 'contract':105 'crown':33,98 'earth':19,104 'elev':75 'express':68 'feet':53 'find':37 'forehead':16,27,83 'full':67 'gaze':110 'gradual':72 'grip':48 'head':36,101 'hip':77 'increas':60 'keep':81 'knee':22,90 'lift':73 'maximum':39 'meet':25 'muscl':108 'necessari':58 'neck':41 'onto':11,17 'part':94 'pose':7,71 'possibl':87 'rabbit':1A 'reach':45 'rest':8 'sasangasana':2C 'shift':28 'skull':97 'strap':56 'stretch':42,62 'sure':79 'thigh':13 'topmost':93 'torso':10 'use':54 'walk':20 'weight':30
98	Happy Baby	Ānanda Bālāsana	Ananda Balasana	From a supine position, on your back, the knees are bent slightly wider than the hips.  The ankles and shins track the knees in a 90 degree angle perpendicular to the earth.  The hands grip the inside sole of the flexed feet (if you have difficultly holding the feet loop a strap over each sole) and push the knees down, coaxing the thighs in toward the torso, lengthening the spine, releasing the tail bone towards the earth and extending the base of the skull away from the back of the neck.  The gaze is up towards the sky.	Beginner	\N	Gently stretches the inner groins and the back spine.  Calms the brain and helps relieve stress and fatigue.	static/img/blissful_baby.png	\N	Corpse	Corpse	{"32": 1, "94": 1, "135": 1, "193": 1, "194": 1, "161": 1, "149": 1, "9": 1}	'90':30 'ananda':3C 'angl':32 'ankl':22 'away':89 'babi':2A 'back':11,92 'balasana':4C 'base':85 'bent':15 'bone':78 'coax':65 'degre':31 'difficult':50 'earth':36,81 'extend':83 'feet':46,53 'flex':45 'gaze':97 'grip':39 'hand':38 'happi':1A 'hip':20 'hold':51 'insid':41 'knee':13,27,63 'lengthen':72 'loop':54 'neck':95 'perpendicular':33 'posit':8 'push':61 'releas':75 'shin':24 'skull':88 'sky':102 'slight':16 'sole':42,59 'spine':74 'strap':56 'supin':7 'tail':77 'thigh':67 'torso':71 'toward':69,79,100 'track':25 'wider':17
102	Supported Headstand (Preparation)	\N	\N	In this inverted posture the body’s weight is balanced between the crown of the head, interlaced fingers (pinky fingers spoon), forearms and the knees.  The interlaced fingers are wrapped around the head with the forearms narrowed to secure the head and protect the neck.  At the same time the back ribs are pushed back to widen the back body as the shoulder blades move away from the ears and pull together securing a safe and strong starting position for full Supported Headstand.  The gaze is naturally towards the knees.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the pituitary and pineal glands.  Strengthens the arms, legs and spine.  Strengthens the lungs.  Tones the abdominal organs.  Improves digestion.  Helps relieve the symptoms of menopause.  Therapeutic for asthma, infertility, insomnia and sinusitis.	static/img/headstand_supported_preparation.png	\N	Supported Headstand	\N	{"101": 1, "13": 1, "148": 1}	'around':34 'away':69 'back':54,58,62 'balanc':13 'blade':67 'bodi':9,63 'crown':16 'ear':72 'finger':21,23,31 'forearm':25,39 'full':84 'gaze':88 'head':19,36,44 'headstand':2A,86 'interlac':20,30 'invert':6 'knee':28,93 'move':68 'narrow':40 'natur':90 'neck':48 'pinki':22 'posit':82 'postur':7 'prepar':3A 'protect':46 'pull':74 'push':57 'rib':55 'safe':78 'secur':42,76 'shoulder':66 'spoon':24 'start':81 'strong':80 'support':1A,85 'time':52 'togeth':75 'toward':91 'weight':11 'widen':60 'wrap':33
32	Corpse	Śavāsana	Savasana	The body rests on the earth in a supine position with the arms resting by the side body.  The palms are relaxed and open toward the sky.  The shoulder blades are pulled back, down and rolled under comfortably, resting evenly on the earth.  The legs are extended down and splayed open.  The heels are in and the toes flop out.  The eyes are closed.  Everything is relaxed.  The gaze is inward.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Relaxes the body.  Reduces headache, fatigue, and insomnia.  Helps to lower blood pressure.	static/img/corpse.png	\N	Boat,Half Boat,Supine Bound Angle,Bridge,Fish,Supine Hand to Toe,Happy Baby,Supine Pigeon,Rejuvenation,Wheel,Wind Removing,One Legged Wind Removing	Boat,Half Boat,Supine Bound Angle,Bridge,Deaf Man's,Fish,Seated Forward Bend,Supine Hand to Toe,Extended Supine Hand to Toe,Happy Baby,Supine Pigeon,Plow,Rejuvenation,Supine Spinal Twist,Wheel,Wind Removing,One Legged Wind Removing	{"6": 1, "7": 1, "9": 1, "13": 2, "17": 1, "73": 1, "78": 1, "94": 1, "98": 1, "135": 1, "149": 1, "190": 1, "193": 1, "194": 1, "169": 1}	'arm':15 'back':35 'blade':32 'bodi':4,20 'close':66 'comfort':40 'corps':1A 'earth':8,45 'even':42 'everyth':67 'extend':49 'eye':64 'flop':61 'gaze':71 'heel':55 'inward':73 'leg':47 'open':26,53 'palm':22 'posit':12 'pull':34 'relax':24,69 'rest':5,16,41 'roll':38 'savasana':2C 'shoulder':31 'side':19 'sky':29 'splay':52 'supin':11 'toe':60 'toward':27
88	Half Moon	Ardha Chandrāsana	Ardha Chandrasana	From a standing position one leg is straight while the other is extended back parallel to the earth (or a little above parallel) and one hand is on the earth (beyond the little-toe side of the foot, about 12 inches) while the other hand is extended up towards the sky.  The shoulder blades are squeezed together and the fingers move outward in opposing directions.  The weight of the body is supported mostly by the standing leg while the bottom hand has very little weight on it but is used intelligently to regulate balance.  The upper torso is rotated open to the sky.  Both hips are externally rotated.  Energy is extended actively through the flexed toes to keep the raised leg strong.  The inner ankle of the standing foot is lifted strongly upward, as if drawing energy from the earth.  The sacrum and scapulae are firmly pressed against the back torso and lengthen the coccyx toward the raised foot.  The gaze is either up or down, depending on the condition of the neck.  If injured the gaze is down.	Intermediate	\N	Strengthens the abdomen, ankles, thighs, buttocks and spine.  Stretches the groins, hamstrings, calves, shoulders, chest and spine.  Improves coordination and sense of balance.  Helps relieve stress.  Improves digestion.	static/img/half_moon_R.png	t	Standing Forward Bend,Bound Half Moon,Standing Splits,Warrior II	Bound Half Moon,Standing Splits,Triangle,Warrior II,Warrior II Forward Bend,Warrior III	{"83": 1, "89": 1.5, "164": 1, "187": 1, "22": 1, "189": 1, "90": 1}	'12':45 'activ':117 'ankl':130 'ardha':3C 'back':18,155 'balanc':99 'beyond':35 'blade':59 'bodi':75 'bottom':85 'chandrasana':4C 'coccyx':160 'condit':175 'depend':172 'direct':70 'draw':141 'earth':22,34,145 'either':168 'energi':114,142 'extend':17,52,116 'extern':112 'finger':65 'firm':151 'flex':120 'foot':43,134,164 'gaze':166,182 'half':1A 'hand':30,50,86 'hip':110 'inch':46 'injur':180 'inner':129 'intellig':96 'keep':123 'leg':10,82,126 'lengthen':158 'lift':136 'littl':25,38,89 'little-to':37 'moon':2A 'most':78 'move':66 'neck':178 'one':9,29 'open':105 'oppos':69 'outward':67 'parallel':19,27 'posit':8 'press':152 'rais':125,163 'regul':98 'rotat':104,113 'sacrum':147 'scapula':149 'shoulder':58 'side':40 'sky':56,108 'squeez':61 'stand':7,81,133 'straight':12 'strong':127,137 'support':77 'toe':39,121 'togeth':62 'torso':102,156 'toward':54,161 'upper':101 'upward':138 'use':95 'weight':72,90
96	Handstand	Adho Mukha Vṛkṣāsana	Adho Mukha Vrksasana	In this inverted posture the weight of the body is on the hands - shoulder-width apart with fingers forward and parallel to each other (if the shoulders are tight, the index fingers are turned out slightly).  The shoulder blades are firm against the back torso and pulled up toward the tailbone.  The upper arms are rotated outward with the eye of the elbow to the front of the room to keep the shoulder blades broad while the outer arms hug inward in opposing forces for balance and stability.  The palms are spread and the bases of the index fingers are pressed firmly against the earth.  Balance is maintained by keeping the Bandhas engaged while pressing the earth away with straight arms and flexed feet.  The gaze is down and forward.	Expert	\N	Strengthens the shoulders, arms and wrists.  Stretches the belly.  Improves sense of balance.  Calms the brain and helps relieve stress and mild depression.	static/img/handstand.png	\N	Flying Man,Handstand with Splits,Scorpion Handstand,Four Limbed Staff	Handstand with Splits,Scorpion Handstand	{"79": 1, "97": 1, "152": 1, "171": 1, "64": 1, "136": 1}	'adho':2C 'apart':21 'arm':59,84,126 'away':123 'back':49 'balanc':91,111 'bandha':117 'base':100 'blade':44,79 'bodi':13 'broad':80 'earth':110,122 'elbow':68 'engag':118 'eye':65 'feet':129 'finger':23,37,104 'firm':46,107 'flex':128 'forc':89 'forward':24,135 'front':71 'gaze':131 'hand':17 'handstand':1A 'hug':85 'index':36,103 'invert':7 'inward':86 'keep':76,115 'maintain':113 'mukha':3C 'oppos':88 'outer':83 'outward':62 'palm':95 'parallel':26 'postur':8 'press':106,120 'pull':52 'room':74 'rotat':61 'shoulder':19,32,43,78 'shoulder-width':18 'slight':41 'spread':97 'stabil':93 'straight':125 'tailbon':56 'tight':34 'torso':50 'toward':54 'turn':39 'upper':58 'vrksasana':4C 'weight':10 'width':20
105	Tripod Headstand with Knees on Elbows	\N	\N	The body is inverted and perpendicular to the earth with the knees resting on the elbows.  The weight of the body is balanced between the crown of the head and the elbows that are bent in a 90-degree angle.  The palms are flat and the fingers point forward.  The head and hands are spaced equally forming an equilateral triangle.  The neck is a natural extension of the spine.  The chin is tucked slightly in towards the sternum.  The gaze is straight.	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the pituitary and pineal glands.  Strengthens the arms, legs, and spine.  Strengthens the lungs.  Tones the abdominal organs.  Improves digestion.  Helps relieve the symptoms of menopause.  Therapeutic for asthma, infertility, insomnia, and sinusitis.	static/img/headstand_tripod_knees_on_elbows.png	\N	Tripod Headstand,Side Splits	Tripod Headstand,Tripod Headstand (Preparation)	{"103": 1, "163": 1, "104": 1, "106": 1}	'90':44 'angl':46 'balanc':29 'bent':41 'bodi':8,27 'chin':77 'crown':32 'degre':45 'earth':15 'elbow':6A,22,38 'equal':62 'equilater':65 'extens':72 'finger':53 'flat':50 'form':63 'forward':55 'gaze':86 'hand':59 'head':35,57 'headstand':2A 'invert':10 'knee':4A,18 'natur':71 'neck':68 'palm':48 'perpendicular':12 'point':54 'rest':19 'slight':80 'space':61 'spine':75 'sternum':84 'straight':88 'toward':82 'triangl':66 'tripod':1A 'tuck':79 'weight':24
106	Tripod Headstand - Spiral the Legs	Parivṛttaikapāda Śīrṣāsana II	Parivrttaikapada Sirsasana II	From Tripod Headstand (Sālamba Śīrṣāsana II), the legs open and extend to the sides into Side Splits and then spiral, first in one direction and then the other.  The gaze is straight.	Expert	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the pituitary and pineal glands.  Strengthens the arms, legs, and spine.  Strengthens the lungs.  Tones the abdominal organs.  Improves digestion.  Helps relieve the symptoms of menopause.  Therapeutic for asthma, infertility, insomnia and sinusitis.	static/img/headstand_tripod_spiral_legs.png	\N	Tripod Headstand	Tripod Headstand	{"103": 1, "105": 1, "64": 1, "83": 1}	'direct':32 'extend':19 'first':29 'gaze':38 'headstand':2A,11 'ii':8C,14 'leg':5A,16 'one':31 'open':17 'parivrttaikapada':6C 'side':22,24 'sirsasana':7C 'spiral':3A,28 'split':25 'straight':40 'sālamba':12 'tripod':1A,10 'śīrṣāsana':13
107	Hero	Vīrāsana	Virasana	From a kneeling position on the floor (with a folded blanket to pad your knees, shins, and feet if necessary) the weight of the body is centered between your feet in a seated position.  If the buttocks don't comfortably rest on the floor, raise them on a block placed between the feet.  Make sure both sitting bones are evenly supported.  There is a thumb's-width space between the inner heels and the outer hips.  The thighs are rotated inward and the heads of the thigh-bones are pressed into the earth with the bases of your palms.  The hands rest on the lap, thighs or soles of the feet.  The shoulder blades are firmed against the back ribs and the top of your sternum is lifted like a proud warrior.  The collarbones are widened as the shoulder blades release away from the ears.  The tailbone lengthens into the floor to anchor the back torso.	Beginner	\N	Stretches the thighs, knees, and ankles.  Strengthens the arches.  Improves digestion and relieves gas.  Helps relieve the symptoms of menopause.  Reduces swelling of the legs during pregnancy (through second trimester).  Therapeutic for high blood pressure and asthma.	static/img/hero.png	\N	Camel,Supine Hero	Camel,Supine Hero,Extended Supine Hero	{"19": 1, "108": 1, "111": 1, "6": 1, "7": 1, "8": 1, "13": 1, "130": 1, "81": 1, "169": 1}	'anchor':157 'away':146 'back':123,159 'base':100 'blade':118,144 'blanket':13 'block':51 'bodi':27 'bone':60,92 'buttock':39 'center':29 'collarbon':138 'comfort':42 'ear':149 'earth':97 'even':62 'feet':20,32,55,115 'firm':120 'floor':9,46,155 'fold':12 'hand':105 'head':87 'heel':75 'hero':1A 'hip':79 'inner':74 'inward':84 'knee':17 'kneel':5 'lap':109 'lengthen':152 'lift':132 'like':133 'make':56 'necessari':22 'outer':78 'pad':15 'palm':103 'place':52 'posit':6,36 'press':94 'proud':135 'rais':47 'releas':145 'rest':43,106 'rib':124 'rotat':83 's-width':68 'seat':35 'shin':18 'shoulder':117,143 'sit':59 'sole':112 'space':71 'sternum':130 'support':63 'sure':57 'tailbon':151 'thigh':81,91,110 'thigh-bon':90 'thumb':67 'top':127 'torso':160 'virasana':2C 'warrior':136 'weight':24 'widen':140 'width':70
51	Crescent Lunge Twist on the Knee	\N	\N	The front foot of one leg is rooted on the earth with the knee directly above and tracking the ankle in a 90 degree angle.  The knee of the back leg is down on the earth.  The inner thighs scissor towards each other and the pelvis is tucked under with the ribcage lifted and the chin slightly tucked.  The spine is long and extended.  The heart is open.  The torso twists towards one side and the arm corresponding towards the back leg reaches towards the back.  Both arms are straight.  Wrists and the fingers are extended and spread wide.  Gaze is over the back shoulder.	Beginner	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, belly, groins (psoas) and the muscles of the back.  Strengthens and stretches the thighs, calves and ankles.	static/img/lunge_crescent_kneeling_twist_R.png	t	Crescent Lunge on the Knee,Reverse Crescent Lunge Twist on the Knee,Lunge on the Knee	Crescent Lunge on the Knee,Reverse Crescent Lunge Twist on the Knee	{"45": 1, "52": 1, "124": 1, "46": 1, "43": 1, "47": 1, "126": 1, "50": 1, "48": 1}	'90':29 'angl':31 'ankl':26 'arm':83,94 'back':36,87,92,110 'chin':62 'correspond':84 'crescent':1A 'degre':30 'direct':21 'earth':17,42 'extend':70,102 'finger':100 'foot':9 'front':8 'gaze':106 'heart':72 'inner':44 'knee':6A,20,33 'leg':12,37,88 'lift':59 'long':68 'lung':2A 'one':11,79 'open':74 'pelvi':52 'reach':89 'ribcag':58 'root':14 'scissor':46 'shoulder':111 'side':80 'slight':63 'spine':66 'spread':104 'straight':96 'thigh':45 'torso':76 'toward':47,78,85,90 'track':24 'tuck':54,64 'twist':3A,77 'wide':105 'wrist':97
114	Locust	Śalabhāsana	Salabhasana	From a supine position lying on the belly (pad the floor below your pelvis and ribs with a folded blanket if needed) with the arms along the side body, palms facing up, lift the legs away from the floor until resting on the lower ribs, belly, and front pelvis with firm buttocks, energy extended thru strong legs and active toes.  The arms are raised parallel to the floor with active fingertips.  Imagine there is a weight pressing down on the backs of the upper arms, and push up toward the ceiling against this resistance.  Press the scapulae firm into the back.  The gaze is forward or slightly upward, being careful not to jut the chin forward and crunch the back of the neck.  Keep the base of the skull lifted and the back of the neck long.	Intermediate	\N	Strengthens muscles of spine, buttocks, and backs of the arms and legs.  Stretches the shoulders, chest, belly, and thighs.  Improves posture.  Stimulates abdominal organs.  Helps relieve stress.	static/img/locust.png	\N	Front Corpse	Front Corpse	{"33": 1, "115": 1, "160": 1, "31": 1}	'activ':61,72 'along':28 'arm':27,64,87 'away':38 'back':83,103,122,135 'base':128 'belli':10,48 'blanket':22 'bodi':31 'buttock':54 'care':112 'ceil':93 'chin':117 'crunch':120 'energi':55 'extend':56 'face':33 'fingertip':73 'firm':53,100 'floor':13,41,70 'fold':21 'forward':107,118 'front':50 'gaze':105 'imagin':74 'jut':115 'keep':126 'leg':37,59 'lie':7 'lift':35,132 'locust':1A 'long':139 'lower':46 'neck':125,138 'need':24 'pad':11 'palm':32 'parallel':67 'pelvi':16,51 'posit':6 'press':79,97 'push':89 'rais':66 'resist':96 'rest':43 'rib':18,47 'salabhasana':2C 'scapula':99 'side':30 'skull':131 'slight':109 'strong':58 'supin':5 'thru':57 'toe':62 'toward':91 'upper':86 'upward':110 'weight':78
113	Standing Knee to Chest	\N	\N	From Tree (Vṛkṣāsana), root your bottom foot to the ground, all four edges of your foot should be touching the ground, then bring the opposite knee into your chest and use the corresponding hand to hold it against your chest.	Intermediate	\N	Improves balance and stability in the legs, strengthens thighs, calves, ankles, and spine, strengthens the ligaments and tendon of the feet, reduces flat feet, increases low back flexibility, reduces low back strain, assists the body in establishing pelvic stability, reduces inflammation and indigestion.	static/img/standing_knee_to_chest_R.png	t	Standing Hand to Toe,Standing Head to Knee (Preparation)	Mountain	{"92": 1, "100": 1, "175": 1, "130": 1, "131": 1, "189": 1}	'bottom':10 'bring':27 'chest':4A,33,44 'correspond':37 'edg':17 'foot':11,20 'four':16 'ground':14,25 'hand':38 'hold':40 'knee':2A,30 'opposit':29 'root':8 'stand':1A 'touch':23 'tree':6 'use':35 'vṛkṣāsana':7
122	Lunge with Arm Extended Up	\N	\N	From Lunge, extend the arm (on the side of the body that correlates to the bent knee) to the sky with fingers spread wide.  The other arm remains on the inside or the outside of the thigh (depending upon your flexibility).  The bottom palm is rooted to the earth for support.  Gaze is towards the sky or towards the earth if your neck is sensitive.	Intermediate	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Opens the shoulders.	static/img/lunge_arm_up_R.png	t	Lunge	Lunge with Arm Extended Forward	{"120": 1, "121": 1}	'arm':3A,9,31 'bent':20 'bodi':15 'bottom':47 'correl':17 'depend':42 'earth':53,64 'extend':4A,7 'finger':26 'flexibl':45 'gaze':56 'insid':35 'knee':21 'lung':1A,6 'neck':67 'outsid':38 'palm':48 'remain':32 'root':50 'sensit':69 'side':12 'sky':24,60 'spread':27 'support':55 'thigh':41 'toward':58,62 'upon':43 'wide':28
67	Downward-Facing Dog with Knee to Forehead	\N	\N	From Downward-Facing Dog (Adho Mukha Śvānāsana), one knee is pulled into the chest or to the forehead depending upon your range of flexibility.  The belly is pulled up and in.  The back is arched in a Cobra position.  The belly is pulled towards the spine and the chin is tucked.  The gaze is down and slightly forward.	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, neck, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.  Warms up the ankles and the toes.  Strengthens abdominal muscles.	static/img/downward_dog_knee_to_forehead_R.png	t	One Legged Downward-Facing Dog,Lunge,Lunge on the Knee,One Legged Plank	Downward-Facing Dog with Bent Knees,One Legged Downward-Facing Dog,One Legged Plank	{"70": 1, "120": 1, "124": 1, "137": 1.5, "64": 1, "136": 1}	'adho':14 'arch':44 'back':42 'belli':35,50 'chest':23 'chin':58 'cobra':47 'depend':28 'dog':4A,13 'downward':2A,11 'downward-fac':1A,10 'face':3A,12 'flexibl':33 'forehead':8A,27 'forward':67 'gaze':62 'knee':6A,18 'mukha':15 'one':17 'posit':48 'pull':20,37,52 'rang':31 'slight':66 'spine':55 'toward':53 'tuck':60 'upon':29 'śvānāsana':16
63	Side Dolphin Plank	\N	\N	In this lateral arm balance position the weight is distributed equally between one forearm and one foot while the other arm extends up with the fingers spread wide and the other foot stacks on top.  The grounded (bottom) foot is flat and gripping the earth from the outside edge of the foot.  If flexibility of the foot is limited then instead of gripping the earth with a flat foot, the weight of the body is balanced on the side edge of the foot that is flexed instead of flat.  The shoulder blades firm against the back and then widen away from the spine drawing toward the tailbone.  Bandhas are engaged to maintain balance and stability.  The crown of the head reaches away from the neck and the gaze is up towards out or up towards the lifted hand.	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Stretches the shoulders, hamstrings, calves, and arches.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica.	static/img/plank_dolphin_side_L.png	t	Dolphin Plank	Dolphin Plank	{"62": 1, "138": 1, "60": 1}	'arm':7,24 'away':103,125 'back':99 'balanc':8,79,116 'bandha':111 'blade':95 'bodi':77 'bottom':41 'crown':120 'distribut':13 'dolphin':2A 'draw':107 'earth':48,68 'edg':52,83 'engag':113 'equal':14 'extend':25 'finger':29 'firm':96 'flat':44,71,92 'flex':89 'flexibl':57 'foot':20,35,42,55,60,72,86 'forearm':17 'gaze':131 'grip':46,66 'ground':40 'hand':141 'head':123 'instead':64,90 'later':6 'lift':140 'limit':62 'maintain':115 'neck':128 'one':16,19 'outsid':51 'plank':3A 'posit':9 'reach':124 'shoulder':94 'side':1A,82 'spine':106 'spread':30 'stabil':118 'stack':36 'tailbon':110 'top':38 'toward':108,134,138 'weight':11,74 'wide':31 'widen':102
75	Extended Puppy	Uttāna Shishosana	Uttana Shishosana	The body is prone to the earth and the forehead, chest and/or chin rest on the earth with the arms extended out in front pressing downward for a deeper stretch.  The hips are at a 90 degree angle to the knees and pulling back towards the heels.  The shins and the top of the feet are extended and firm on the earth.  (A blanket can be used under the chin to relax the neck if needed).  There is a slight curve in the lower back and the gaze is forward.	Intermediate	\N	Stretches the spine and shoulders.	static/img/puppy_extended.png	\N	Box	Box	{"13": 1, "28": 1, "29": 1, "85": 1, "64": 1, "60": 1}	'90':40 'and/or':16 'angl':42 'arm':24 'back':48,89 'blanket':68 'bodi':6 'chest':15 'chin':17,74 'curv':85 'deeper':33 'degre':41 'downward':30 'earth':11,21,66 'extend':1A,25,61 'feet':59 'firm':63 'forehead':14 'forward':94 'front':28 'gaze':92 'heel':51 'hip':36 'knee':45 'lower':88 'neck':78 'need':80 'press':29 'prone':8 'pull':47 'puppi':2A 'relax':76 'rest':18 'shin':53 'shishosana':4C 'slight':84 'stretch':34 'top':56 'toward':49 'use':71 'uttana':3C
121	Lunge with Arm Extended Forward	\N	\N	From Lunge, the arm (on the side of the body that correlates to the front bent knee) is extended forward with fingers spread wide and the palm facing inward.  The other arm remains on the inside of the thigh with the palm rooted into the earth for support.  The gaze is forward.	Beginner	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Opens the shoulders.	static/img/lunge_arm_forward_R.png	t	Lunge,Lunge with Arm Extended Up	Lunge	{"120": 1, "122": 1, "125": 1, "136": 1, "185": 1}	'arm':3A,9,37 'bent':21 'bodi':15 'correl':17 'earth':51 'extend':4A,24 'face':33 'finger':27 'forward':5A,25,57 'front':20 'gaze':55 'insid':41 'inward':34 'knee':22 'lung':1A,7 'palm':32,47 'remain':38 'root':48 'side':12 'spread':28 'support':53 'thigh':44 'wide':29
118	Lotus	Padmāsana	Padmasana	From Half Lotus (Ardha Padmāsana), bring the bottom ankle and place it on top of the opposite knee, both ankles will be resting on top of the thighs.	Intermediate	\N	Opens the hips, groin and stretches the knees, ankles and thighs.  Strengthens the back and calms the mind, reduces stress and anxiety.  Improves circulation and blood flow in the pelvis.	static/img/lotus_full.png	t	\N	Half Lotus	{"119": 1, "73": 1, "169": 1, "81": 1}	'ankl':11,22 'ardha':6 'bottom':10 'bring':8 'half':4 'knee':20 'lotus':1A,5 'opposit':19 'padmasana':2C 'padmāsana':7 'place':13 'rest':25 'thigh':30 'top':16,27
127	Lunge on the Knee with Hands on the Inside of the Leg	\N	\N	From Downward-Facing Dog (Adho Mukha Śvānāsana) pose, step your foot between your hands to a lunge position.  The back knee is down.  The arms are straight and positioned on the inside of the front leg.  The palms of the hands are pushing the ground away from the body.  Straight line of energy is maintained throughout the spine.  If a deeper stretch is desired, both forearms may be brought down to the floor and a block may be used for modification.	Beginner	\N	Opens hips and hip flexors.  Works the quadriceps and lubricates the joints.  Increases flexibility.	static/img/lunge_kneeling_hands_on_mat_R.png	t	\N	\N	{"120": 1, "123": 1, "86": 1}	'adho':18 'arm':38 'away':59 'back':33 'block':89 'bodi':62 'brought':82 'deeper':74 'desir':77 'dog':17 'downward':15 'downward-fac':14 'energi':66 'face':16 'floor':86 'foot':24 'forearm':79 'front':48 'ground':58 'hand':6A,27,54 'insid':9A,45 'knee':4A,34 'leg':12A,49 'line':64 'lung':1A,30 'maintain':68 'may':80,90 'modif':94 'mukha':19 'palm':51 'pose':21 'posit':31,42 'push':56 'spine':71 'step':22 'straight':40,63 'stretch':75 'throughout':69 'use':92 'śvānāsana':20
119	Half Lotus	Ardha Padmāsana	Ardha Padmasana	From a seated position, bend one knee and bring the ankle to the crease of the opposite hip so the sole of the foot faces the sky.  Bend the other knee, and cross the ankle beneath the opposite knee.  Place the hands on the thighs or knees and keep the spine straight.	Beginner	\N	Opens the hips and stretches the knees and ankles.  Strengthens the back and calms the mind, reduces stress and anxiety.  Improves circulation and blood flow in the pelvis.	static/img/lotus_half.png	t	Lotus	\N	{"118": 1, "36": 1, "73": 1, "169": 1, "81": 1}	'ankl':15,39 'ardha':3C 'bend':9,32 'beneath':40 'bring':13 'creas':18 'cross':37 'face':29 'foot':28 'half':1A 'hand':46 'hip':22 'keep':53 'knee':11,35,43,51 'lotus':2A 'one':10 'opposit':21,42 'padmasana':4C 'place':44 'posit':8 'seat':7 'sky':31 'sole':25 'spine':55 'straight':56 'thigh':49
131	Mountain with Arms Up	Tāḍāsana	Tadasana	From Mountain (Tāḍāsana), the arms are lifted up toward the sky with the elbows straight and the biceps by the ears.  The palms are open and face each other with the fingers spread wide.  The pelvis is tucked.  The ribcage is lifted.  The gaze is toward the sky.	Beginner	\N	Improves posture.  Strengthens thighs, knees, and ankles.  Firms abdomen and buttocks.  Relieves sciatica.  Reduces flat feet.	static/img/mountain_arms_up.png	\N	Standing Forward Bend,Standing Forward Bend with Shoulder Opener,Mountain	Standing Forward Bend,Standing Forward Bend with Shoulder Opener,Mountain	{"83": 2.0, "84": 1, "130": 2.0, "53": 1}	'arm':3A,9 'bicep':22 'ear':25 'elbow':18 'face':31 'finger':36 'gaze':48 'lift':11,46 'mountain':1A,6 'open':29 'palm':27 'pelvi':40 'ribcag':44 'sky':15,52 'spread':37 'straight':19 'tadasana':4C 'toward':13,50 'tuck':42 'tāḍāsana':7 'wide':38
153	Supported Shoulder Stand	Sālamba Sarvāṅgāsana	Salamba Sarvangasana	From a supine position, the upper back is resting on the earth with the hips straight up towards the sky.  The torso is perpendicular to the earth.  The legs are fully extended and the toes are active.  The hands are either supporting the lower back or extended up by the side body in matchstick.  The neck is flat on the earth and the chin is tucked in.  The gaze is inward.	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the thyroid and prostate glands and abdominal organs.  Stretches the shoulders and neck.  Tones the legs and buttocks.  Improves digestion.  Helps relieve the symptoms of menopause.  Reduces fatigue and alleviates insomnia.  Therapeutic for asthma, infertility, and sinusitis.	static/img/shoulderstand_supported.png	\N	Plow,Unsupported Shoulder Stand	Rejuvenation	{"144": 1, "154": 1, "149": 1, "32": 1}	'activ':42 'back':12,50 'bodi':57 'chin':69 'earth':17,32,66 'either':46 'extend':37,52 'flat':63 'fulli':36 'gaze':74 'hand':44 'hip':20 'inward':76 'leg':34 'lower':49 'matchstick':59 'neck':61 'perpendicular':29 'posit':9 'rest':14 'salamba':4C 'sarvangasana':5C 'shoulder':2A 'side':56 'sky':25 'stand':3A 'straight':21 'supin':8 'support':1A,47 'toe':40 'torso':27 'toward':23 'tuck':71 'upper':11
155	Bound Side Angle	Baddha Pārśvakoṇāsana	Baddha Parsvakonasana	From Extended Side Angle (Utthita Pārśvakoṇāsana), one arm is wrapped underneath the front thigh while the other hand wraps around the torso behind the back in a bind.  The ribcage is lifted and the pelvis tucked.  The heart is open.  The gaze is towards the sky.	Expert	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Opens the shoulders.	static/img/lunge_bind_R.png	t	Bound Revolved Chair,Lunge with Hands on the Inside of the Leg,Warrior II Forward Bend	Bound Revolved Chair,Extended Side Angle,Warrior II Forward Bend	{"26": 1, "123": 1, "188": 1, "156": 1}	'angl':3A,9 'arm':13 'around':25 'back':30 'baddha':4C 'behind':28 'bind':33 'bound':1A 'extend':7 'front':18 'gaze':47 'hand':23 'heart':43 'lift':37 'one':12 'open':45 'parsvakonasana':5C 'pelvi':40 'pārśvakoṇāsana':11 'ribcag':35 'side':2A,8 'sky':51 'thigh':19 'torso':27 'toward':49 'tuck':41 'underneath':16 'utthita':10 'wrap':15,24
64	Downward-Facing Dog	Adho Mukha Śvānāsana	Adho Mukha Svanasana	The body is positioned in an inverted "V" with the palms and feet rooted into the earth and sits bones lifted up towards the sky.  The arms and legs are straight.  The weight of the body is equally distributed between the hands and the feet.  The eye of the elbows face forward.  The ribcage is lifted and the heart is open.  Shoulders are squared to the earth and rotated back, down and inward.  The neck is relaxed and the crown of the head is toward the earth.  The gaze is down and slightly forward.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.  Warms up the ankles and the toes.	static/img/downward_dog.png	\N	Box,Downward-Facing Dog with Bent Knees,Downward-Facing Dog with Toe Raises,One Legged Downward-Facing Dog,Revolved Downward-Facing Dog,Halfway Lift,Tripod Headstand,Plank,Plank on the Knees,Side Splits,Warrior I	Box,Downward-Facing Dog with Bent Knees,Downward-Facing Dog with Toe Raises,One Legged Downward-Facing Dog,Revolved Downward-Facing Dog,Tripod Headstand,Plank,Upward-Facing Dog	{"13": 1, "65": 1, "69": 1, "70": 1, "71": 1, "91": 2.0, "103": 1, "136": 2.0, "143": 1, "163": 1, "182": 2.0, "37": 2.0, "120": 1, "83": 1, "66": 1, "68": 1, "60": 1, "67": 1, "105": 1}	'adho':5C 'arm':34 'back':77 'bodi':9,43 'bone':27 'crown':87 'distribut':46 'dog':4A 'downward':2A 'downward-fac':1A 'earth':24,74,94 'elbow':57 'equal':45 'eye':54 'face':3A,58 'feet':20,52 'forward':59,101 'gaze':96 'hand':49 'head':90 'heart':66 'invert':14 'inward':80 'leg':36 'lift':28,63 'mukha':6C 'neck':82 'open':68 'palm':18 'posit':11 'relax':84 'ribcag':61 'root':21 'rotat':76 'shoulder':69 'sit':26 'sky':32 'slight':100 'squar':71 'straight':38 'svanasana':7C 'toward':30,92 'v':15 'weight':40
137	One Legged Plank	Eka Pāda Phalakāsana	Eka Pada Phalakasana	The body is parallel to the earth.  Straight arms and the active toes of one leg support the weight of the body.  The other leg is extended off the earth and reaches to the back with active toes.  The abdomen is pulled up towards the spine and the pelvis is tucked.  The neck is a natural extension of the spine and the chin is slightly tucked.  The palms are flat and the elbows are close to the side body.  The joints are stacked with the wrists, elbows and shoulders in a straight line.  The gaze is down following the straight line of the spine.	Intermediate	\N	Strengthens the arms, wrists and spine.  Tones the abdomen.	static/img/plank_leg_up_R.png	t	Downward-Facing Dog with Knee to Forehead,One Legged Downward-Facing Dog	Downward-Facing Dog with Knee to Forehead,One Legged Downward-Facing Dog	{"67": 1, "70": 1, "136": 1}	'abdomen':46 'activ':18,43 'arm':15 'back':41 'bodi':8,28,85 'chin':69 'close':81 'earth':13,36 'eka':4C 'elbow':79,93 'extend':33 'extens':63 'flat':76 'follow':104 'gaze':101 'joint':87 'leg':2A,22,31 'line':99,107 'natur':62 'neck':59 'one':1A,21 'pada':5C 'palm':74 'parallel':10 'pelvi':55 'phalakasana':6C 'plank':3A 'pull':48 'reach':38 'shoulder':95 'side':84 'slight':71 'spine':52,66,110 'stack':89 'straight':14,98,106 'support':23 'toe':19,44 'toward':50 'tuck':57,72 'weight':25 'wrist':92
156	Extended Side Angle	Utthita Pārśvakoṇāsana	Utthita Parsvakonasana	From Warrior II (Vīrabhadrāsana II), the lower body stays static while the upper body is folded forward at the crease of the hip.  One arm is extended toward the front with the bicep by the ear and the fingers spread wide while the other reaches down to the earth on the inside of the thigh.  The upper torso and the gaze twist up towards the sky.	Intermediate	\N	Strengthens and stretches the legs, knees, and ankles.  Stretches the groin, spine, waist, chest, lungs, and shoulders.  Stimulates abdominal organs.  Increases stamina.	static/img/warrior_II_forward_arm_forward_R.png	t	Lunge with Hands on the Inside of the Leg,Bound Side Angle,Reverse Warrior	Reverse Warrior,Warrior II Forward Bend	{"123": 1, "155": 1, "180": 1, "177": 1, "187": 1, "39": 1, "120": 1}	'angl':3A 'arm':30 'bicep':38 'bodi':13,19 'creas':25 'ear':41 'earth':54 'extend':1A,32 'finger':44 'fold':21 'forward':22 'front':35 'gaze':66 'hip':28 'ii':8,10 'insid':57 'lower':12 'one':29 'parsvakonasana':5C 'reach':50 'side':2A 'sky':71 'spread':45 'static':15 'stay':14 'thigh':60 'torso':63 'toward':33,69 'twist':67 'upper':18,62 'utthita':4C 'vīrabhadrāsana':9 'warrior':7 'wide':46
134	Flying Pigeon	Eka Pāda Gālavāsana	Eka Pada Galavasana	Begin in Tree (Vṛkṣāsana) pose, standing on one leg.  Release the foot from the inner thigh and place the ankle above the opposite knee.  Bend the standing knee and fold forward, bringing the palms to the floor.  Bend the elbows to about 90 degrees and hook the toes of the foot on the opposite upper arm.  Bring the weight of the body forward as the standing foot comes off.  Start to straighten the leg behind.	Expert	\N	Strengthens the abdominal muscles and arms.  Stretches the hamstrings.	static/img/pigeon_flying_R.png	t	Tree	Tree	{"175": 1, "171": 1, "136": 1, "137": 1, "83": 1}	'90':48 'ankl':25 'arm':61 'begin':6 'behind':80 'bend':30,43 'bodi':67 'bring':37,62 'come':73 'degre':49 'eka':3C 'elbow':45 'fli':1A 'floor':42 'fold':35 'foot':17,56,72 'forward':36,68 'galavasana':5C 'hook':51 'inner':20 'knee':29,33 'leg':14,79 'one':13 'opposit':28,59 'pada':4C 'palm':39 'pigeon':2A 'place':23 'pose':10 'releas':15 'stand':11,32,71 'start':75 'straighten':77 'thigh':21 'toe':53 'tree':8 'upper':60 'vṛkṣāsana':9 'weight':64
154	Unsupported Shoulder Stand	Nirālamba Sarvāṅgāsana	Niralamba Sarvangasana	From Supported Shoulder Stand (Sālamba Sarvāṅgāsana) the arms lift straight up along the side body towards the sky with the fingers spread wide.  The gaze is up.	Expert	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the thyroid and prostate glands and abdominal organs.  Stretches the shoulders and neck.  Tones the legs and buttocks.  Improves digestion.  Helps relieve the symptoms of menopause.  Reduces fatigue and alleviates insomnia.  Therapeutic for asthma.	static/img/shoulderstand_unsupported.png	\N	Plow	Supported Shoulder Stand	{"144": 1, "153": 1, "149": 1, "32": 1}	'along':17 'arm':13 'bodi':20 'finger':26 'gaze':30 'lift':14 'niralamba':4C 'sarvangasana':5C 'sarvāṅgāsana':11 'shoulder':2A,8 'side':19 'sky':23 'spread':27 'stand':3A,9 'straight':15 'support':7 'sālamba':10 'toward':21 'unsupport':1A 'wide':28
135	Supine Pigeon	Supta Kapotāsana	Supta Kapotasana	Lie on the back in supine position.  Bend the knees, heels close to SI bones and cross one ankle over the opposite knee.  Thread the hands or reach through between the thighs.  Lift the foot off the floor and hold the bent knee behind the thigh or shin to bring it closer to the chest, make sure that the acrum is rooted to the floor.	Intermediate	\N	Stretches the hamstrings and quads.  If the elbow is used to push the thigh, it opens the hips as well.	static/img/supine_pigeon_R.png	t	Corpse	Corpse	{"32": 1, "8": 1, "9": 1, "98": 1, "161": 1, "193": 1}	'acrum':64 'ankl':23 'back':8 'behind':48 'bend':12 'bent':46 'bone':19 'bring':54 'chest':59 'close':16 'closer':56 'cross':21 'floor':42,69 'foot':39 'hand':30 'heel':15 'hold':44 'kapotasana':4C 'knee':14,27,47 'lie':5 'lift':37 'make':60 'one':22 'opposit':26 'pigeon':2A 'posit':11 'reach':32 'root':66 'shin':52 'si':18 'supin':1A,10 'supta':3C 'sure':61 'thigh':36,50 'thread':28
142	Side Plank on the Knee	\N	\N	From Box (Cakravākāsana), one leg is extended back with the outside edge of the foot gripping the earth.  The top arm (on the same side of the body as the extended leg) is extended up to the sky with the fingers spread wide.  The supporting leg is bent and the foot and the knee are angled out for balance.  The supporting arm is straight and in line the extended arm with the joints stacked.  The pelvis is tucked under to protect the lumbar spine and the gaze is up.	Beginner	\N	Strengthens the arms, belly and legs.  Stretches and strengthens the wrists.  Stretches the backs of the legs.  Improves sense of balance and focus.	static/img/plank_kneeling_side_L.png	t	Side Plank,Plank on the Knees	Plank,Plank on the Knees	{"138": 1, "143": 1}	'angl':61 'arm':26,67,75 'back':13 'balanc':64 'bent':53 'bodi':33 'box':7 'cakravākāsana':8 'earth':23 'edg':17 'extend':12,36,39,74 'finger':46 'foot':20,56 'gaze':92 'grip':21 'joint':78 'knee':5A,59 'leg':10,37,51 'line':72 'lumbar':88 'one':9 'outsid':16 'pelvi':81 'plank':2A 'protect':86 'side':1A,30 'sky':43 'spine':89 'spread':47 'stack':79 'straight':69 'support':50,66 'top':25 'tuck':83 'wide':48
140	Upward Plank	Pūrvottānāsana	Purvottanasana	From Staff (Daṇḍāsana) place the hands on the floor about one foot behind the hips with the fingertips pointed forward towards the hips.  On an inhale press through the hands and feet to lift the hips as high as possible.  Keep the inner line of the feet together and seal them into the mat as much as possible.  Relax the head back and gaze at the tip of your nose.	Intermediate	\N	Strengthens the arms, the wrists, and the legs.  Stretches the shoulders, the chest, and the front ankles.	static/img/plank_upward.png	\N	Staff	Table	{"169": 1, "172": 1}	'back':65 'behind':16 'daṇḍāsana':6 'feet':35,50 'fingertip':21 'floor':12 'foot':15 'forward':23 'gaze':67 'hand':9,33 'head':64 'high':41 'hip':18,26,39 'inhal':29 'inner':46 'keep':44 'lift':37 'line':47 'mat':57 'much':59 'nose':73 'one':14 'place':7 'plank':2A 'point':22 'possibl':43,61 'press':30 'purvottanasana':3C 'relax':62 'seal':53 'staff':5 'tip':70 'togeth':51 'toward':24 'upward':1A
84	Standing Forward Bend with Shoulder Opener	Uttānāsana	Uttanasana	From a standing position, the body is folded over at the crease of the hip with the spine long.  The neck is relaxed and the crown of the head is towards the earth.  The feet are rooted into the earth.  The toes are actively lifted.  The spine is straight.  The ribcage is lifted.  The chest and the thighs are connected.  The sacrum lifts up toward the sky in dog tilt.  The fingers are interlaced behind the body and the palms are together.  The arms and elbows are straight.  The shoulder blades rotate towards each other as the hands move forward (away from the lower back).  The gaze is down and inward.	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the liver and kidneys.  Stretches the hamstrings, calves, and hips.  Strengthens the thighs and knees.  Improves digestion.  Helps relieve the symptoms of menopause.  Reduces fatigue and anxiety.  Relieves headache and insomnia.  Relieves headache and insomnia.  Opens the shoulders.	static/img/forward_bend_deep.png	\N	Chair,Halfway Lift,Mountain with Arms Up	Chair,Halfway Lift,Mountain with Arms Up	{"22": 1, "91": 1, "131": 1, "176": 1, "20": 1, "83": 1}	'activ':51 'arm':91 'away':108 'back':112 'behind':82 'bend':3A 'blade':98 'bodi':13,84 'chest':62 'connect':67 'creas':19 'crown':33 'dog':76 'earth':40,47 'elbow':93 'feet':42 'finger':79 'fold':15 'forward':2A,107 'gaze':114 'hand':105 'head':36 'hip':22 'interlac':81 'inward':118 'lift':52,60,70 'long':26 'lower':111 'move':106 'neck':28 'open':6A 'palm':87 'posit':11 'relax':30 'ribcag':58 'root':44 'rotat':99 'sacrum':69 'shoulder':5A,97 'sky':74 'spine':25,54 'stand':1A,10 'straight':56,95 'thigh':65 'tilt':77 'toe':49 'togeth':89 'toward':38,72,100 'uttanasana':7C
159	Sleeping Swan	\N	\N	From One Legged King Pigeon (Preparation), begin bending forward from the hips, with the hands on the ground and outstretched in front of you.  Keep the weight back into the hips as you lower yourself to the ground.  Move down first to the forearms, then to the forehead, and eventually to the chest, as flexibility allows.  Stretch your arms out as far as they may reach.	Intermediate	\N	Provides a gentle, potent opening of the hips, and external rotation of the front hip.  Stretches the quadriceps and hip flexors of the back leg.	static/img/pigeon_forward_bend_R.png	t	One Legged King Pigeon (Preparation)	One Legged King Pigeon (Preparation)	{"111": 1, "28": 1, "29": 1, "13": 1}	'allow':58 'arm':61 'back':30 'begin':9 'bend':10 'chest':55 'eventu':52 'far':64 'first':43 'flexibl':57 'forearm':46 'forehead':50 'forward':11 'front':24 'ground':20,40 'hand':17 'hip':14,33 'keep':27 'king':6 'leg':5 'lower':36 'may':67 'move':41 'one':4 'outstretch':22 'pigeon':7 'prepar':8 'reach':68 'sleep':1A 'stretch':59 'swan':2A 'weight':29
158	Bound Revolved Side Angle	Parivṛtta Baddha Pārśvakoṇāsana	Parivrtta Baddha Parsvakonasana	From Warrior II (Vīrabhadrāsana II), bend the front knee and spin to the ball of the back foot as the torso lowers down onto the thigh, opening the heart center to the sky and lowering the bottom hand to the inside of the thigh with the palm planted firmly.  At the same time, reach the top arm and hand up and overhead extending in a straight line towards the front.  To take the bind then wrap the top arm around and under the backside of the torso and grasp the bottom hand at the wrist if possible.  Minimize lateral flexion of the spine while rotating the torso open.  Press the elbow and the shoulder against the bent knee in an isometric contraction to keep the knee aligned and leverage the rotation of the torso.  The gaze is to upper fingertips and the neck is relaxed.  As all twists lengthen and soften the belly, extend the spine with each inhalation, and increase the twist as you exhale.	Expert	\N	Strengthens and stretches the legs, the knees, and the ankles.  Stretches the groins, the spine, the chest, the lungs, and the shoulders.  Stimulates abdominal organs.  Increases stamina.  Improves digestion and aids elimination.  Improves balance.	static/img/warrior_twist_extended_bound_R.png	t	Revolved Bird of Paradise (Preparation),Revolved Side Angle	Revolved Bird of Paradise (Preparation),Revolved Side Angle	{"5": 1, "157": 1}	'align':134 'angl':4A 'arm':64,86 'around':87 'back':24 'backsid':91 'baddha':6C 'ball':21 'belli':160 'bend':13 'bent':124 'bind':81 'bottom':44,98 'bound':1A 'center':37 'contract':129 'elbow':118 'exhal':173 'extend':70,161 'fingertip':147 'firm':56 'flexion':107 'foot':25 'front':15,77 'gaze':143 'grasp':96 'hand':45,66,99 'heart':36 'ii':10,12 'increas':168 'inhal':166 'insid':48 'isometr':128 'keep':131 'knee':16,125,133 'later':106 'lengthen':156 'leverag':136 'line':74 'lower':29,42 'minim':105 'neck':150 'onto':31 'open':34,115 'overhead':69 'palm':54 'parivrtta':5C 'parsvakonasana':7C 'plant':55 'possibl':104 'press':116 'reach':61 'relax':152 'revolv':2A 'rotat':112,138 'shoulder':121 'side':3A 'sky':40 'soften':158 'spin':18 'spine':110,163 'straight':73 'take':79 'thigh':33,51 'time':60 'top':63,85 'torso':28,94,114,141 'toward':75 'twist':155,170 'upper':146 'vīrabhadrāsana':11 'warrior':9 'wrap':83 'wrist':102
42	Bound Revolved Crescent Lunge	Parivṛtta Baddha Aṅjaneyāsana	Parivrtta Baddha Anjaneyasana	From Revolved Crescent Lunge with Extended Arms (Utthita Parivṛtta Aṅjaneyāsana), lower the top hand around the back with palm facing out.  Bottom hand wraps underneath the thigh.  Bend the elbow and extend the hand to reach the other hand.  Bind the hands together.  If the hands cannot reach, use a strap.  Heart is open.  The gaze is over the top shoulder.	Intermediate	\N	Deeply stretches the spine, chest, lungs, shoulders and groin.  Stimulates the internal abdominal organs and kidneys.	static/img/lunge_twist_extended_bound_R.png	t	Revolved Bird of Paradise (Preparation),Revolved Crescent Lunge with Extended Arms	Revolved Bird of Paradise (Preparation),Revolved Crescent Lunge with Extended Arms	{"5": 1, "41": 1, "24": 1, "25": 1}	'anjaneyasana':7C 'arm':14 'around':22 'aṅjaneyāsana':17 'back':24 'baddha':6C 'bend':35 'bind':47 'bottom':29 'bound':1A 'cannot':54 'crescent':3A,10 'elbow':37 'extend':13,39 'face':27 'gaze':63 'hand':21,30,41,46,49,53 'heart':59 'lower':18 'lung':4A,11 'open':61 'palm':26 'parivrtta':5C 'parivṛtta':16 'reach':43,55 'revolv':2A,9 'shoulder':68 'strap':58 'thigh':34 'togeth':50 'top':20,67 'underneath':32 'use':56 'utthita':15 'wrap':31
147	Pyramid on the Knee	\N	\N	From a standing position the front and back legs extend away from each other and the inner thighs scissor towards each other.  Drop the back knee on the mat and the top foot flat.  The spine is long and extended as the upper torso folds over the front leg and the palms on the floor.  Keep the front leg straight	Intermediate	\N	Stretches the spine, hips, and hamstrings.  Strengthens the legs.  Stimulates the abdominal organs.	static/img/pyramid_kneeling_R.png	t	Crescent Lunge on the Knee,Lunge on the Knee	Crescent Lunge on the Knee,Lunge on the Knee	{"45": 1, "124": 1}	'away':15 'back':12,29 'drop':27 'extend':14,44 'flat':38 'floor':59 'fold':49 'foot':37 'front':10,52,62 'inner':21 'keep':60 'knee':4A,30 'leg':13,53,63 'long':42 'mat':33 'palm':56 'posit':8 'pyramid':1A 'scissor':23 'spine':40 'stand':7 'straight':64 'thigh':22 'top':36 'torso':48 'toward':24 'upper':47
181	Warrior Twist	\N	\N	From Warrior I with Prayer Hands, the torso twists towards the sky as the heart opens.  The opposite elbow connects with the outside of the front bent knee.  The gaze is towards the sky unless the neck is sensitive then the gaze stays down towards the earth.	Intermediate	\N	Wrings out the lower back and the digestive and vital organs of the mid-body.  Opens the chest.  Stretches the pectoralis minor muscles.	static/img/warrior_twist_R.png	t	Revolved Side Angle,Warrior I with Prayer Hands	Revolved Side Angle,Warrior I with Prayer Hands	{"157": 1, "184": 1}	'bent':29 'connect':22 'earth':49 'elbow':21 'front':28 'gaze':32,44 'hand':8 'heart':17 'knee':30 'neck':39 'open':18 'opposit':20 'outsid':25 'prayer':7 'sensit':41 'sky':14,36 'stay':45 'torso':10 'toward':12,34,47 'twist':2A,11 'unless':37 'warrior':1A,4
65	Downward-Facing Dog with Bent Knees	\N	\N	From Downward-Facing Dog (Adho Mukha Śvānāsana), the arms are extended straight and the knees are bent with the sits bones tilted up and reaching for the sky in dog tilt.  The belly is pulled in and up.  The gaze is towards the belly.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.  Warms up the ankles, toes, knees and hamstrings.	static/img/downward_dog_bent_knees.png	\N	Downward-Facing Dog,Downward-Facing Dog with Knee to Forehead,Standing Forward Bend,Lunge,Lunge on the Knee	Downward-Facing Dog	{"64": 1, "67": 1, "83": 1, "120": 1, "124": 1, "91": 1, "136": 1, "143": 1, "66": 1, "69": 1, "71": 1}	'adho':13 'arm':17 'belli':41,52 'bent':6A,25 'bone':29 'dog':4A,12,38 'downward':2A,10 'downward-fac':1A,9 'extend':19 'face':3A,11 'gaze':48 'knee':7A,23 'mukha':14 'pull':43 'reach':33 'sit':28 'sky':36 'straight':20 'tilt':30,39 'toward':50 'śvānāsana':15
151	Scorpion	Vṛśchikāsana I	Vrschikasana I	From Feathered Peacock (Pīñcha Mayūrāsana) the knees are bent and the feet are lowered towards the head as the crown of the head lifts and the upper thoracic reaches through to the front.  To maintain balance the ribs move back and shoulders lower back and away from the ears as the forearms and palms push into the earth.  The knees may separate, but keep the toes together.  The gaze is forward or up depending on your flexibility.	Expert	\N	Strengthens the shoulders, arms, abdominals and back.  Stretches the spine, hips and neck.  Improves balance and focus.	static/img/scorpion.png	\N	Feathered Peacock	Feathered Peacock	{"132": 1, "60": 1, "61": 1, "62": 1}	'away':48 'back':42,46 'balanc':38 'bent':11 'crown':22 'depend':76 'ear':51 'earth':60 'feather':4 'feet':14 'flexibl':79 'forearm':54 'forward':73 'front':35 'gaze':71 'head':19,25 'keep':66 'knee':9,62 'lift':26 'lower':16,45 'maintain':37 'may':63 'mayūrāsana':7 'move':41 'palm':56 'peacock':5 'push':57 'pīñcha':6 'reach':31 'rib':40 'scorpion':1A 'separ':64 'shoulder':44 'thorac':30 'toe':68 'togeth':69 'toward':17 'upper':29 'vrschikasana':2C
152	Scorpion Handstand	Vṛśchikāsana II	Vrschikasana II	From Handstand (Adho Mukha Vṛkṣāsana) the ribs move back, the shoulders shift down and away from the ears, the pelvis tucks under for balance as the knees bend and the feet drop towards the head.  The heart center goes forward while the crown of the head lifts up.  The gaze is down or forward depending on balance and flexibility.	Expert	\N	The entire front of the body is stretched, especially the chest, neck, spine and abs.  Strengthens the arms, shoulders and back.  Stimulates the abdominal organs and lungs.  Increases blood flow to the brain and circulation in the limbs.  Can increase fertility through stimulation of the reproductive organs.	static/img/handstand_scorpion.png	\N	Handstand	Handstand	{"96": 1, "97": 1, "171": 1, "136": 1, "64": 1}	'adho':7 'away':19 'back':13 'balanc':28,61 'bend':32 'center':42 'crown':47 'depend':59 'drop':36 'ear':22 'feet':35 'flexibl':63 'forward':44,58 'gaze':54 'goe':43 'handstand':2A,6 'head':39,50 'heart':41 'ii':4C 'knee':31 'lift':51 'move':12 'mukha':8 'pelvi':24 'rib':11 'scorpion':1A 'shift':16 'shoulder':15 'toward':37 'tuck':25 'vrschikasana':3C 'vṛkṣāsana':9
150	Scale	Tolāsana	Tolasana	The palms press into the earth, supporting the weight of the body with the elbows straight.  The legs are wrapped around the elbows, extended forward and hooked at the ankles with the feet lifted into the full expression of the pose.  The ribcage is lifted.  The gaze is forward.	Intermediate	\N	Strengthens arms and wrists.  Improves focus and concentration.  Opens flexibility of lower body.	static/img/scale.png	\N	Firefly,Side Splits	Tortoise,Tortoise (Preparation)	{"77": 1, "163": 1, "86": 1, "174": 1}	'ankl':32 'around':23 'bodi':14 'earth':8 'elbow':17,25 'express':40 'extend':26 'feet':35 'forward':27,51 'full':39 'gaze':49 'hook':29 'leg':20 'lift':36,47 'palm':4 'pose':43 'press':5 'ribcag':45 'scale':1A 'straight':18 'support':9 'tolasana':2C 'weight':11 'wrap':22
160	Sphinx	Sālamba Bhujaṅgāsana	Salamba Bhujangasana	From a prone position with the pelvic bowl is firmly contracted interiorly towards the center line of the body while the pubis is tucked under.  The legs are extended back and the tops of the feet are flat.  The palms are flat and the elbows are on the mat, stacked right below the shoulders.  On an inhalation, lift the sternum and extend the neck away from shoulders with the elbows, palms and pelvic bone firmly attached to the mat.	Beginner	\N	Strengthens the spine.  Stretches the chest, the lungs, the shoulders and the abdomen.  Stimulates the abdominal organs.  Opens the heart and the lungs.	static/img/sphinx.png	\N	Front Corpse	Front Corpse	{"33": 1, "78": 1, "31": 1, "179": 1, "136": 1, "62": 1, "13": 1}	'attach':79 'away':68 'back':33 'bhujangasana':3C 'bodi':22 'bone':77 'bowl':11 'center':18 'contract':14 'elbow':48,73 'extend':32,65 'feet':39 'firm':13,78 'flat':41,45 'inhal':60 'interior':15 'leg':30 'lift':61 'line':19 'mat':52,82 'neck':67 'palm':43,74 'pelvic':10,76 'posit':7 'prone':6 'pubi':25 'right':54 'salamba':2C 'shoulder':57,70 'sphinx':1A 'stack':53 'sternum':63 'top':36 'toward':16 'tuck':27
161	Supine Spinal Twist	Supta Jaṭhara Parivartānāsana	Supta Jathara Parivartanasana	From supine position, bent one knee and cross it outside of the opposite foot.  Use the hand to put slight pressure on the bent knee to push down towards the floor.  Keep both shoulders squared and rooted to the floor.  Extend the opposite hand and gaze towards the hand.  For a deeper stretch, start to straighten the bent knee.	Beginner	\N	Stretches the back muscles and spine.  Stimulates the kidneys, abdominal organs, urinary bladders and intestines.  Releases stress.  If the knee is straightened, it stretches the hamstrings and strengthens the legs.	static/img/supine_spinal_twist_R.png	t	Corpse	One Legged Wind Removing	{"32": 1, "94": 1, "98": 1, "135": 1, "149": 1, "193": 1, "194": 1}	'bent':10,30,64 'cross':14 'deeper':58 'extend':47 'floor':37,46 'foot':20 'gaze':52 'hand':23,50,55 'jathara':5C 'keep':38 'knee':12,31,65 'one':11 'opposit':19,49 'outsid':16 'parivartanasana':6C 'posit':9 'pressur':27 'push':33 'put':25 'root':43 'shoulder':40 'slight':26 'spinal':2A 'squar':41 'start':60 'straighten':62 'stretch':59 'supin':1A,8 'supta':4C 'toward':35,53 'twist':3A 'use':21
162	Front Splits	Hanumānāsana	Hanumanasana	The hips are parallel and squared to the earth with one leg extended forward.  The opposite leg extended back with the knee and foot squared to the earth.  The inner thighs scissor towards each other.  The hands are by the side body or at the heart center in Anjali Mudra (Salutation Seal) or stretched straight up toward the sky.  The ribcage is lifted.  The heart is open.  The gaze is forward.	Expert	\N	Stretches the thighs, hamstrings, and groin.  Stimulates the abdominal organs.	static/img/splits_front_R.png	t	Cow Face (Preparation),One Legged Downward-Facing Dog	One Legged Downward-Facing Dog,One Legged King Pigeon (Preparation)	{"36": 1, "70": 1, "169": 1}	'anjali':52 'back':22 'bodi':45 'center':50 'earth':12,31 'extend':16,21 'foot':27 'forward':17,74 'front':1A 'gaze':72 'hand':40 'hanumanasana':3C 'heart':49,68 'hip':5 'inner':33 'knee':25 'leg':15,20 'lift':66 'mudra':53 'one':14 'open':70 'opposit':19 'parallel':7 'ribcag':64 'salut':54 'scissor':35 'seal':55 'side':44 'sky':62 'split':2A 'squar':9,28 'straight':58 'stretch':57 'thigh':34 'toward':36,60
157	Revolved Side Angle	Parivṛtta Pārśvakoṇāsana	Parivrtta Parsvakonasana	From a standing position, the legs are in a wide stance with the feet aligned and flat on the earth.  The inner thighs scissor towards each other with Mula Bandha engaged.  The front knee is bent in a 90-degree angle and tracks the front ankle.  The back leg is straight with most of the body’s weight pressed into the outside edge of the back foot gripping the earth.  From the center of the back, between the shoulder blades, the arms move away from the torso that is rotated up towards the sky.  One arm is actively reaching up and the other actively reaching down utilizing the fingers tips or flat palm only as a un-weighted balancing tool.  The elbow of the bottom hand is either on the inside or the outside of the bent front knee, depending on the degree of flexibility available.  Beginning students should keep their head in a neutral position, looking straight forward, or turn it to look down and protect the neck.  More experienced students can turn the head and gaze up at the top thumb.	Intermediate	\N	Wrings out the lower back and the digestive and vital organs of the mid-body.  Opens the chest.  Stretches the pectoralis minor muscles.	static/img/warrior_twist_extended_R.png	t	Bound Revolved Side Angle,Warrior Twist	Bound Revolved Side Angle,Warrior Twist	{"158": 1, "181": 1, "120": 1}	'90':44 'activ':103,109 'align':20 'angl':3A,46 'ankl':51 'arm':87,101 'avail':152 'away':89 'back':53,71,81 'balanc':125 'bandha':35 'begin':153 'bent':41,143 'blade':85 'bodi':61 'bottom':131 'center':78 'degre':45,149 'depend':146 'earth':25,75 'edg':68 'either':134 'elbow':128 'engag':36 'experienc':177 'feet':19 'finger':114 'flat':22,117 'flexibl':151 'foot':72 'forward':165 'front':38,50,144 'gaze':184 'grip':73 'hand':132 'head':158,182 'inner':27 'insid':137 'keep':156 'knee':39,145 'leg':11,54 'look':163,170 'move':88 'mula':34 'neck':175 'neutral':161 'one':100 'outsid':67,140 'palm':118 'parivrtta':4C 'parsvakonasana':5C 'posit':9,162 'press':64 'protect':173 'reach':104,110 'revolv':1A 'rotat':95 'scissor':29 'shoulder':84 'side':2A 'sky':99 'stanc':16 'stand':8 'straight':56,164 'student':154,178 'thigh':28 'thumb':189 'tip':115 'tool':126 'top':188 'torso':92 'toward':30,97 'track':48 'turn':167,180 'un':123 'un-weight':122 'util':112 'weight':63,124 'wide':15
78	Fish	Matsyāsana	Matsyasana	From a supine position, lying on the back, the pelvis and upper torso are arched up and lift off the earth.  The head is released back and rests on the crown of the head (there should be a minimal amount of weight on the head to avoid crunching the neck).  The scapulae are pressed firm towards each other.  The arms are extended overhead with steepled fingers while simultaneously the legs are lifted up with the toes engaged sending prana to the extremities.  The gaze is either up towards the sky or to the back of room, depending on your flexibility.	Intermediate	\N	A traditional text states that Matsyasana is the "destroyer of all diseases".  Stretches the deep hip flexors (psoas) and the muscles (intercostals) between the ribs.  Stretches and stimulates the muscles of the belly and front of the neck.  Stretches and stimulates the organs of the belly and throat.  Strengthens the muscles of the upper back and back of the neck.  Improves posture.	static/img/fish.png	\N	Corpse	Corpse	{"32": 1, "17": 1, "6": 1, "7": 1, "170": 1}	'amount':42 'arch':17 'arm':62 'avoid':49 'back':10,28,96 'crown':33 'crunch':50 'depend':99 'earth':23 'either':88 'engag':79 'extend':64 'extrem':84 'finger':68 'firm':57 'fish':1A 'flexibl':102 'gaze':86 'head':25,36,47 'leg':72 'lie':7 'lift':20,74 'matsyasana':2C 'minim':41 'neck':52 'overhead':65 'pelvi':12 'posit':6 'prana':81 'press':56 'releas':27 'rest':30 'room':98 'scapula':54 'send':80 'simultan':70 'sky':92 'steepl':67 'supin':5 'toe':78 'torso':15 'toward':58,90 'upper':14 'weight':44
14	Box with Knee to Forehead	\N	\N	From Box (Cakravākāsana), one knee is pulled into the chest or to the forehead as flexibility allows.  The belly is pulled up and in.  The back is arched in a Cobra position with the chin tucked.  The gaze is down and slightly forward.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, neck, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.  Warms up the ankles and the toes.  Strengthens abdominal muscles.	static/img/downward_dog_knee_to_forehead_kneeling_R.png	t	One Legged Plank on the Knee	One Legged Plank on the Knee	{"141": 1, "2": 1, "13": 1, "16": 1}	'allow':22 'arch':33 'back':31 'belli':24 'box':1A,7 'cakravākāsana':8 'chest':15 'chin':40 'cobra':36 'flexibl':21 'forehead':5A,19 'forward':48 'gaze':43 'knee':3A,10 'one':9 'posit':37 'pull':12,26 'slight':47 'tuck':41
168	Bound Revolved Squatting Toe Balance	Pāśasana	Pasasana	From Revolved Squatting Toe Balance, bring the top arm up and around the back to meet the bottom arm that will reach under and wrap around its respective knee to be met at the wrist by the top hand.  On the inhale, elongate the spine and on the exhale take the twist slightly deeper.  Keep the heart open and the gaze should be slightly over the top shoulder. 	Expert	\N	Strengthens arms, wrists and ankles.  Stretches the upper back.  Strengthens the abdominal muscles.	static/img/seated_on_heels_twist_bound_L.png	t	Revolved Squatting Toe Balance	Revolved Squatting Toe Balance	{"167": 1, "165": 1, "58": 1}	'arm':15,25 'around':18,32 'back':20 'balanc':5A,11 'bottom':24 'bound':1A 'bring':12 'deeper':60 'elong':49 'exhal':55 'gaze':67 'hand':45 'heart':63 'inhal':48 'keep':61 'knee':35 'meet':22 'met':38 'open':64 'pasasana':6C 'reach':28 'respect':34 'revolv':2A,8 'shoulder':74 'slight':59,70 'spine':51 'squat':3A,9 'take':56 'toe':4A,10 'top':14,44,73 'twist':58 'wrap':31 'wrist':41
164	Standing Splits	Ūrdhva Prasārita Eka Pādāsana	Urdhva Prasarita Eka Padasana	From a standing posture the weight of the body is balanced on one foot, the front torso is resting on the thigh and the other leg is extended up.  The proper balance of external and internal rotation in each leg is important, especially for the standing leg.  Specifically, pay attention to the angle of the knee.  Keep the kneecap facing straight ahead.  Feel how the downward energy of the standing leg creates an upward movement in the raised leg.  Don't focus on how high the raised leg goes; instead, work toward directing equal energy into both legs.  Hold the raised leg more or less parallel to the floor, or raise it slightly higher; ideally the torso should descend as the lifted leg ascends.  The gaze is out in front of you.	Intermediate	\N	Calms the brain.  Stimulates the liver and kidneys.  Stretches the hamstrings, calves, and thighs.  Strengthens the thighs, knees, and ankles.  Stretches the back of the leg, the front thigh and groin.	static/img/splits_standing_R.png	t	Standing Forward Bend,Half Moon,Revolved Half Moon	Standing Forward Bend,Half Moon,Revolved Half Moon,Lunge,Lunge on the Knee	{"83": 1, "88": 1.5, "90": 1, "189": 1}	'ahead':68 'angl':59 'ascend':130 'attent':56 'balanc':17,38 'bodi':15 'creat':78 'descend':125 'direct':99 'downward':72 'eka':5C 'energi':73,101 'equal':100 'especi':49 'extend':34 'extern':40 'face':66 'feel':69 'floor':115 'focus':88 'foot':20 'front':22,136 'gaze':132 'goe':95 'high':91 'higher':120 'hold':105 'ideal':121 'import':48 'instead':96 'intern':42 'keep':63 'knee':62 'kneecap':65 'leg':32,46,53,77,85,94,104,108,129 'less':111 'lift':128 'movement':81 'one':19 'padasana':6C 'parallel':112 'pay':55 'postur':10 'prasarita':4C 'proper':37 'rais':84,93,107,117 'rest':25 'rotat':43 'slight':119 'specif':54 'split':2A 'stand':1A,9,52,76 'straight':67 'thigh':28 'torso':23,123 'toward':98 'upward':80 'urdhva':3C 'weight':12 'work':97
166	Squatting Toe Balance with Opened Knees	\N	\N	The weight of the body is seated on the heels with the knees open to the sides.  The hands are at the heart in prayer position.  The belly is pulled up and in towards the spine with the ribcage and chin lifted.  The gaze is forward and slightly down.	Beginner	\N	Strengthens arms, wrists and ankles.  Stretches the upper back.  Strengthens the abdominal muscles.  Opens the groin.  Tones the abdominal organs.	static/img/seated_on_heels_prayer_opened_knees.png	\N	Crow (Preparation)	Squatting Toe Balance	{"55": 1, "165": 1, "86": 1, "83": 1}	'balanc':3A 'belli':34 'bodi':11 'chin':47 'forward':52 'gaze':50 'hand':25 'heart':29 'heel':16 'knee':6A,19 'lift':48 'open':5A,20 'posit':32 'prayer':31 'pull':36 'ribcag':45 'seat':13 'side':23 'slight':54 'spine':42 'squat':1A 'toe':2A 'toward':40 'weight':8
165	Squatting Toe Balance	\N	\N	The weight of the body is seated on the heels with the knees closed and the hands are at the heart in prayer position.  The pelvis is tucked.  The belly is pulled up and in towards the spine.  The ribcage and chin are lifted.  The gaze is forward and slightly down.	Beginner	\N	Strengthens arms, wrists and ankles.  Stretches the upper back.  Strengthens the abdominal muscles.  Opens the groin.  Tones the abdominal organs.	static/img/seated_on_heels_prayer.png	\N	Squatting Toe Balance with Opened Knees,Revolved Squatting Toe Balance	Halfway Lift,Revolved Squatting Toe Balance	{"166": 1, "167": 1, "86": 1, "83": 1, "55": 1}	'balanc':3A 'belli':33 'bodi':8 'chin':45 'close':17 'forward':51 'gaze':49 'hand':20 'heart':24 'heel':13 'knee':16 'lift':47 'pelvi':29 'posit':27 'prayer':26 'pull':35 'ribcag':43 'seat':10 'slight':53 'spine':41 'squat':1A 'toe':2A 'toward':39 'tuck':31 'weight':5
167	Revolved Squatting Toe Balance	\N	\N	Start from Squatting Toe Balance pose.  Slowly twist to one side, hooking the elbow to the outside of the opposite knee.  Gaze is towards the sky.  If possible, release the hands, lower hand wraps around the knees and the other hand around the back and try to bind the hands.	Intermediate	\N	Strengthens arms, wrists and ankles.  Stretches the upper back.  Strengthens the abdominal muscles.	static/img/seated_on_heels_prayer_twist_L.png	t	Side Crow (Preparation),Squatting Toe Balance,Bound Revolved Squatting Toe Balance	Side Crow (Preparation),Squatting Toe Balance,Bound Revolved Squatting Toe Balance	{"58": 1, "165": 1, "168": 1}	'around':39,46 'back':48 'balanc':4A,9 'bind':52 'elbow':18 'gaze':26 'hand':35,37,45,54 'hook':16 'knee':25,41 'lower':36 'one':14 'opposit':24 'outsid':21 'pose':10 'possibl':32 'releas':33 'revolv':1A 'side':15 'sky':30 'slowli':11 'squat':2A,7 'start':5 'toe':3A,8 'toward':28 'tri':50 'twist':12 'wrap':38
171	Four Limbed Staff	Chaturaṅga Daṇḍāsana	Chaturanga Dandasana	From a prone position, the weight of the body is supported on the hands and the toes.  The body is approximately 5 inches above and parallel to the earth.  The abdomen is pulled up towards the spine.  The pelvis is tucked.  The palms are flat.  The elbows are close to the side body and bent in a 90-degree angle and inline with the wrists.  The toes are rooted into the earth as the heels push back.  The gaze is down.	Intermediate	\N	Strengthens the arms and wrists.  Tones the abdomens.	static/img/four_limbed_staff.png	\N	Upward-Facing Dog	Crescent Lunge on the Knee,Crow,Flying Man,Halfway Lift,Handstand,Plank,Plank on the Knees,Warrior I,Warrior II	{"179": 4.0, "64": 1, "136": 1, "31": 1}	'5':27 '90':63 'abdomen':36 'angl':65 'approxim':26 'back':82 'bent':60 'bodi':14,24,58 'chaturanga':4C 'close':54 'dandasana':5C 'degre':64 'earth':34,77 'elbow':52 'flat':50 'four':1A 'gaze':84 'hand':19 'heel':80 'inch':28 'inlin':67 'limb':2A 'palm':48 'parallel':31 'pelvi':44 'posit':9 'prone':8 'pull':38 'push':81 'root':74 'side':57 'spine':42 'staff':3A 'support':16 'toe':22,72 'toward':40 'tuck':46 'weight':11 'wrist':70
175	Tree	Vṛkṣāsana	Vrksasana	From a standing position, one foot is rooted into the earth with the opposite heel rooted into the inner thigh with the toes pointing towards the earth.  The pelvis and the chin are tucked in.  The arms are lifted above the head with the palms together in prayer position.  The gaze is forward.	Intermediate	\N	Strengthens the legs, ankles, and feet.  Improves flexibility in the hips and knees.  Improves balance.	static/img/tree_L.png	t	Mountain,Flying Pigeon	Mountain,Flying Pigeon	{"130": 1, "134": 1, "116": 1, "189": 1, "113": 1, "100": 1, "131": 1, "1": 1}	'arm':39 'chin':34 'earth':13,29 'foot':8 'forward':55 'gaze':53 'head':44 'heel':17 'inner':21 'lift':41 'one':7 'opposit':16 'palm':47 'pelvi':31 'point':26 'posit':6,51 'prayer':50 'root':10,18 'stand':5 'thigh':22 'toe':25 'togeth':48 'toward':27 'tree':1A 'tuck':36 'vrksasana':2C
173	Tortoise	Kūrmāsana	Kurmasana	From Tortoise (Preparation), the hands and the elbows press thru the legs, then wrap back  around  to the opposite side of the torso into a bind at the small of the back.  The gaze is down.	Expert	\N	Stretches the insides and backs of the legs.  Stimulates the abdominal organs.  Strengthens the spine.  Calms the brain.  Releases groin.  Releases the elbows.	static/img/tortoise_bind.png	\N	Scale	Tortoise (Preparation)	{"150": 1, "174": 1}	'around':18 'back':17,34 'bind':28 'elbow':10 'gaze':36 'hand':7 'kurmasana':2C 'leg':14 'opposit':21 'prepar':5 'press':11 'side':22 'small':31 'thru':12 'torso':25 'tortois':1A,4 'wrap':16
172	Table	Pūrvottānāsana	Purvottanasana	From Staff (Daṇḍāsana) place the hands on the floor about one foot behind the hips with the fingertips pointed forward towards hips.  Keep knees bent and feet close to hips while pressing through the hands and feet to lift the hips creating an inverted U with the body into Table.  Relax the head back and gaze at the tip of your nose.	Beginner	\N	Strengthens the arms, the wrists, and the legs.  Stretches the shoulders, the chest, and the front ankles.	static/img/table.png	\N	Upward Plank,Staff	Staff	{"140": 1, "169": 1}	'back':56 'behind':15 'bent':27 'bodi':50 'close':30 'creat':44 'daṇḍāsana':5 'feet':29,39 'fingertip':20 'floor':11 'foot':14 'forward':22 'gaze':58 'hand':8,37 'head':55 'hip':17,24,32,43 'invert':46 'keep':25 'knee':26 'lift':41 'nose':64 'one':13 'place':6 'point':21 'press':34 'purvottanasana':2C 'relax':53 'staff':4 'tabl':1A,52 'tip':61 'toward':23 'u':47
170	Inverted Staff	Dvi Pāda Viparīta Daṇḍāsana	Dvi Pada Viparita Dandasana	Start with the preparatory steps of Wheel (Ūrdhva Dhanurāsana).  Then with the crown of the head on the floor draw the elbows to the floor shoulder-distance apart and interlace the fingers around the head as in Supported Headstand (Sālamba Śīrṣāsana I).  Press firmly into the forearms and lift the head off the floor, extend the legs straight, draw the feet together and energize down through the legs and feet.	Expert	\N	Stretches the entire front body and opens the chest.  Tones the internal organs.  Revitalizes the central nervous system.	static/img/staff_inverted.png	\N	\N	\N	{"140": 1, "78": 1, "190": 1, "169": 1}	'apart':35 'around':40 'crown':19 'dandasana':6C 'dhanurāsana':15 'distanc':34 'draw':26,66 'dvi':3C 'elbow':28 'energ':71 'extend':62 'feet':68,77 'finger':39 'firm':51 'floor':25,31,61 'forearm':54 'head':22,42,58 'headstand':46 'interlac':37 'invert':1A 'leg':64,75 'lift':56 'pada':4C 'preparatori':10 'press':50 'shoulder':33 'shoulder-dist':32 'staff':2A 'start':7 'step':11 'straight':65 'support':45 'sālamba':47 'togeth':69 'viparita':5C 'wheel':13 'śīrṣāsana':48 'ūrdhva':14
180	Reverse Warrior	Pārśva Vīrabhadrāsana	Parsva Virabhadrasana	From Warrior II (Vīrabhadrāsana II), the lower body stays static while the upper body arches back in a gentle back bend.  The top arm is extended back with the bicep by the ear and the fingers spread wide.  The other arm slides down the back leg resting on the thigh or shin, but not the knee joint.  The gaze is up towards the sky.	Intermediate	\N	Strengthens and stretches the legs, knees, and ankles.  Stretches the groin, spine, waist, chest, lungs, and shoulders.  Stimulates abdominal organs.  Increases stamina.  Relieves backaches, especially through second trimester of pregnancy.  Therapeutic for carpal tunnel syndrome, flat feet, infertility, osteoporosis, and sciatica.	static/img/warrior_II_reverse_R.png	t	Lunge,Lunge on the Knee,Extended Side Angle,Warrior II,Warrior II Forward Bend	Lunge,Extended Side Angle,Warrior II,Warrior II Forward Bend	{"120": 1, "124": 1, "156": 1.5, "187": 1, "188": 1, "189": 1, "182": 1, "183": 1, "185": 1}	'arch':19 'arm':28,45 'back':20,24,31,49 'bend':25 'bicep':34 'bodi':12,18 'ear':37 'extend':30 'finger':40 'gaze':63 'gentl':23 'ii':7,9 'joint':61 'knee':60 'leg':50 'lower':11 'parsva':3C 'rest':51 'revers':1A 'shin':56 'sky':68 'slide':46 'spread':41 'static':14 'stay':13 'thigh':54 'top':27 'toward':66 'upper':17 'virabhadrasana':4C 'vīrabhadrāsana':8 'warrior':2A,6 'wide':42
178	Revolved Triangle	Parivṛtta Trikoṇāsana	Parivrtta Trikonasana	From a standing position the weight of the body is distributed equally between the front and back leg.  The legs are in a wide stance, parallel and scissor towards each other.  The back foot is at a 45 to 60 degree angle and the front and back heels are aligned.  The forward thigh is turned outward so that the center of the kneecap is in line with the center of the ankle.  The torso opens towards the sky while the hips are squared as much as possible.  The top hand extends up while the bottom hand is either on the earth (inside or outside the foot) or, if flexibility is limited, on a block positioned against the inner sole of the foot.  From the center of the back, between the shoulder blades, the arms press away from the torso.  Beginning students should keep their head in a neutral position and look forward or turn the gaze towards the earth.  More experienced students can turn the head and gaze up at the top thumb as a Dristhi point.	Intermediate	\N	Calms the brain.  Stimulates the liver and kidneys.  Stretches the hamstrings, calves, and thighs.  Strengthens the thighs, knees, and ankles.  Stretches the back of the leg, the front thigh and groin.	static/img/triangle_revolved_R.png	t	Revolved Half Moon,Triangle (Preparation)	Triangle (Preparation)	{"90": 1, "177": 1}	'45':42 '60':44 'align':54 'angl':46 'ankl':76 'arm':138 'away':140 'back':21,37,51,132 'begin':144 'blade':136 'block':118 'bodi':13 'bottom':99 'center':64,73,129 'degre':45 'distribut':15 'dristhi':180 'earth':105,163 'either':102 'equal':16 'experienc':165 'extend':95 'flexibl':113 'foot':38,110,126 'forward':56,156 'front':19,49 'gaze':160,172 'hand':94,100 'head':149,170 'heel':52 'hip':85 'inner':122 'insid':106 'keep':147 'kneecap':67 'leg':22,24 'limit':115 'line':70 'look':155 'much':89 'neutral':152 'open':79 'outsid':108 'outward':60 'parallel':30 'parivrtta':3C 'point':181 'posit':8,119,153 'possibl':91 'press':139 'revolv':1A 'scissor':32 'shoulder':135 'sky':82 'sole':123 'squar':87 'stanc':29 'stand':7 'student':145,166 'thigh':57 'thumb':177 'top':93,176 'torso':78,143 'toward':33,80,161 'triangl':2A 'trikonasana':4C 'turn':59,158,168 'weight':10 'wide':28
81	Seated Forward Bend	Paśchimottānāsana	Paschimottanasana	From a seated position with the sits bones rooted into the earth the legs extend forward to the degree that the chest and thighs can stay connected.  The fingers wrap around the toes.  The upper torso folds forward at the crease of the hips with the spine long.  The gaze is forward.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Stretches the spine, shoulders and hamstrings.  Stimulates the liver, kidneys, ovaries and uterus.  Improves digestion.  Helps relieve the symptoms of menopause and menstrual discomfort.  Soothes headache and anxiety.  Reduces fatigue.  Therapeutic for high blood pressure, infertility, insomnia and sinusitis.  Traditional texts say that Paschimottanasana increases appetite, reduces obesity and cures diseases.	static/img/seated_forward_bend.png	\N	Corpse	Seated Forward Bend (Preparation)	{"32": 1, "6": 1, "21": 1, "73": 1, "7": 1, "76": 1, "128": 1, "129": 1, "163": 1, "169": 1}	'around':35 'bend':3A 'bone':12 'chest':26 'connect':31 'creas':45 'degre':23 'earth':16 'extend':19 'finger':33 'fold':41 'forward':2A,20,42,56 'gaze':54 'hip':48 'leg':18 'long':52 'paschimottanasana':4C 'posit':8 'root':13 'seat':1A,7 'sit':11 'spine':51 'stay':30 'thigh':28 'toe':37 'torso':40 'upper':39 'wrap':34
176	Triangle	Trikoṇāsana	Trikonasana	From a standing position, the legs are straight and separated into a wide stance.  The feet are aligned and flat on the earth with the back foot in a 60-degree angle towards the front.  The inner thighs are rotated externally away from each other.  The pelvis is tucked and the ribcage is lifted.  One arm extends up towards the sky as the other reaches down to the earth.  Both arms are aligned with the shoulders in a straight line.  The fingers reach out as the shoulder blades squeeze together.  The gaze is toward the front.	Beginner	\N	Stretches and strengthens the thighs, knees, and ankles.  Stretches the hips, groin, hamstrings, calves, shoulders, chest, and spine.  Stimulates the abdominal organs.  Helps relieve stress.  Improves digestion.  Helps relieve the symptoms of menopause.  Relieves backache, especially through second trimester of pregnancy.  Therapeutic for anxiety, flat feet, infertility, neck pain, osteoporosis, and sciatica.	static/img/triangle_forward_R.png	t	Half Moon,Triangle (Preparation)	Triangle (Preparation)	{"88": 1, "177": 1, "90": 1, "163": 1, "64": 1, "145": 1}	'60':32 'align':20,75 'angl':34 'arm':58,73 'away':44 'back':28 'blade':90 'degre':33 'earth':25,71 'extend':59 'extern':43 'feet':18 'finger':84 'flat':22 'foot':29 'front':37,98 'gaze':94 'inner':39 'leg':8 'lift':56 'line':82 'one':57 'pelvi':49 'posit':6 'reach':67,85 'ribcag':54 'rotat':42 'separ':12 'shoulder':78,89 'sky':63 'squeez':91 'stanc':16 'stand':5 'straight':10,81 'thigh':40 'togeth':92 'toward':35,61,96 'triangl':1A 'trikonasana':2C 'tuck':51 'wide':15
82	Seated Forward Bend (Preparation)	\N	\N	From a seated position with the sits bones rooted into the earth the knees are bent.  The thighs connect with the chest.  The peace fingers are wrapped around the big toes.  The ribcage is lifted.  The gaze is forward.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Stretches the spine, shoulders and hamstrings.  Stimulates the liver, kidneys, ovaries and uterus.  Improves digestion.  Helps relieve the symptoms of menopause and menstrual discomfort.  Soothes headache and anxiety.  Reduces fatigue.  Therapeutic for high blood pressure, infertility, insomnia and sinusitis.	static/img/seated_forward_bend_preparation.png	\N	Seated Forward Bend	Box	{"81": 1}	'around':32 'bend':3A 'bent':20 'big':34 'bone':12 'chest':26 'connect':23 'earth':16 'finger':29 'forward':2A,43 'gaze':41 'knee':18 'lift':39 'peac':28 'posit':8 'prepar':4A 'ribcag':37 'root':13 'seat':1A,7 'sit':11 'thigh':22 'toe':35 'wrap':31
183	Warrior I with Hands on Hips	\N	\N	From a standing position, the legs are in a wide stance with the feet aligned and flat on the earth.  The back foot is in a 60-degree angle towards the front.  The hips are squared.  The inner thighs are rotated towards each other.  The front knee is bent in a 90-degree angle directly above the ankle.  The pelvis is tucked.  The ribcage is lifted.  The arms are by the side body with the hands resting on the hips.  The gaze is forward.	Beginner	\N	Stretches the chest, lungs, neck, belly and groin (psoas).  Strengthens the back muscles.  Strengthens and stretches the thighs, calves and ankles.	static/img/warrior_I_hands_on_hips_R.png	t	Warrior I,Warrior I Forward Bend with Hands on Hips,Warrior II	Warrior I,Warrior I Forward Bend with Hands on Hips	{"182": 1, "186": 1, "187": 1, "184": 1, "37": 1, "120": 1}	'60':33 '90':58 'align':21 'angl':35,60 'ankl':64 'arm':74 'back':28 'bent':55 'bodi':79 'degre':34,59 'direct':61 'earth':26 'feet':20 'flat':23 'foot':29 'forward':90 'front':38,52 'gaze':88 'hand':4A,82 'hip':6A,40,86 'inner':44 'knee':53 'leg':12 'lift':72 'pelvi':66 'posit':10 'rest':83 'ribcag':70 'rotat':47 'side':78 'squar':42 'stanc':17 'stand':9 'thigh':45 'toward':36,48 'tuck':68 'warrior':1A 'wide':16
184	Warrior I with Prayer Hands	\N	\N	From Warrior I (Vīrabhadrāsana I), the hands come to the heart in prayer position	Beginner	\N	Stretches the chest, lungs, shoulders, neck, belly and groin (psoas).  Strengthens and stretches the thighs, calves and ankles.	static/img/warrior_prayer_R.png	t	Warrior Twist,Warrior I,Warrior II	Warrior Twist,Warrior I,Warrior II	{"181": 1, "182": 1, "187": 1, "120": 1, "37": 1, "180": 1, "186": 1, "183": 1}	'come':13 'hand':5A,12 'heart':16 'posit':19 'prayer':4A,18 'vīrabhadrāsana':9 'warrior':1A,7
177	Triangle (Preparation)	\N	\N	From a standing position, both legs are straight and separated into a wide stance.  The feet are aligned and flat on the earth with the back foot in a 60-degree angle towards the front.  The inner thighs are rotated externally away from each other.  The pelvis tucked in.  The ribcage lifted.  The arms are extended out in a straight line parallel to the earth.  The palms are prone and the fingers are extended out.  The shoulder blades are squeezed together.  The gaze is toward the front fingers.	Beginner	\N	Stretches and strengthens the thighs, knees and ankles.  Stretches the hips, groin, hamstrings, calves, shoulders, chest and spine.  Stimulates the abdominal organs.  Helps relieve stress.  Improves digestion.  Helps relieve the symptoms of menopause.  Relieves backache, especially through second trimester of pregnancy.  Therapeutic for anxiety, flat feet, infertility, neck pain, osteoporosis and sciatica.	static/img/triangle_R.png	t	Triangle,Revolved Triangle,Warrior II	Triangle,Revolved Triangle,Warrior II	{"145": 1.5, "176": 1, "178": 1, "187": 1.5}	'60':32 'align':20 'angl':34 'arm':56 'away':44 'back':28 'blade':80 'degre':33 'earth':25,67 'extend':58,76 'extern':43 'feet':18 'finger':74,90 'flat':22 'foot':29 'front':37,89 'gaze':85 'inner':39 'leg':8 'lift':54 'line':63 'palm':69 'parallel':64 'pelvi':49 'posit':6 'prepar':2A 'prone':71 'ribcag':53 'rotat':42 'separ':12 'shoulder':79 'squeez':82 'stanc':16 'stand':5 'straight':10,62 'thigh':40 'togeth':83 'toward':35,87 'triangl':1A 'tuck':50 'wide':15
13	Box	Cakravākāsana	Cakravakasana	From a kneeling position, the knees and arms form a box with the spine and neck in a neutral position.  The hips and shoulders are squared to the earth and the palms are rooted with the weight of the body equally distributed between the heel of the hands and the top of the knees.  The joints are stacked with the wrists, elbows and shoulders in a straight line.  The gaze is down.	Beginner	\N	Increases abdominal strength.  Warms up the joints, muscles of arms and the legs.	static/img/box_neutral.png	\N	Balancing the Cat,Box with Shoulder Stretch,Extended Child's,Wide Child's,Front Corpse,Cow,Dolphin,Downward-Facing Dog,Extended Puppy,Seated Forward Bend (Preparation),One Legged King Pigeon (Preparation)	Balancing the Cat,Half Bow,Box with Shoulder Stretch,Cat,Child's,Extended Child's,Wide Child's,Front Corpse,Cow Face (Preparation),Downward-Facing Dog,Extended Puppy,Marichi's III,Plank,Side Splits	{"2": 1, "15": 1, "28": 1, "29": 1, "33": 1, "34": 1, "60": 1, "64": 1, "75": 1, "82": 1, "111": 1, "20": 1, "136": 1, "102": 1}	'arm':10 'bodi':42 'box':1A,13 'cakravakasana':2C 'distribut':44 'earth':31 'elbow':64 'equal':43 'form':11 'gaze':72 'hand':50 'heel':47 'hip':24 'joint':58 'knee':8,56 'kneel':5 'line':70 'neck':18 'neutral':21 'palm':34 'posit':6,22 'root':36 'shoulder':26,66 'spine':16 'squar':28 'stack':60 'straight':69 'top':53 'weight':39 'wrist':63
191	One Legged Wheel	Eka Pāda Ūrdhva Dhanurāsana	Eka Pada Urdhva Dhanurasana	From Wheel (Ūrdhva Dhanurāsana), extend one leg straight up to the sky with active toes.  The gaze is forward.	Expert	\N	Strengthens the arms, wrists, legs, buttocks, abs, and spine.  Stimulates the thyroid and pituitary.  Increases energy and counteracts depression.  Therapeutic for asthma, back pain, infertility, and osteoporosis.	static/img/wheel_leg_up_R.png	t	Wheel	Wheel	{"190": 1}	'activ':21 'dhanurasana':7C 'dhanurāsana':11 'eka':4C 'extend':12 'forward':26 'gaze':24 'leg':2A,14 'one':1A,13 'pada':5C 'sky':19 'straight':15 'toe':22 'urdhva':6C 'wheel':3A,9 'ūrdhva':10
188	Warrior II Forward Bend	Pārśvakoṇāsana	Parsvakonasana	From Warrior II (Vīrabhadrāsana II), the lower body stays static while the upper body folds forward at the crease of the hip.  One arm is extended toward the sky while the other reaches down to the earth.  The fingers reach out as the shoulder blades squeeze together.  The gaze is towards the sky.	Intermediate	\N	Strengthens and stretches the legs, knees and ankles.  Stretches the groin, spine, waist, chest, lungs and shoulders.  Stimulates abdominal organs.  Increases stamina.	static/img/warrior_II_forward_R.png	t	Half Moon,Bound Side Angle,Extended Side Angle,Reverse Warrior,Warrior II	Bound Side Angle,Reverse Warrior,Warrior II	{"88": 1, "155": 1, "156": 1, "180": 1, "187": 1, "120": 1, "157": 1}	'arm':29 'bend':4A 'blade':50 'bodi':13,19 'creas':24 'earth':42 'extend':31 'finger':44 'fold':20 'forward':3A,21 'gaze':54 'hip':27 'ii':2A,8,10 'lower':12 'one':28 'parsvakonasana':5C 'reach':38,45 'shoulder':49 'sky':34,58 'squeez':51 'static':15 'stay':14 'togeth':52 'toward':32,56 'upper':18 'vīrabhadrāsana':9 'warrior':1A,7
4	Revolved Bird of Paradise	Parivṛtta Svarga Dvijāsana	Parivrtta Svarga Dvijasana	From Revolved Chair (Parivṛtta Utkaṭāsana) pose, the lower arm reaches back around the legs as the upper arm wraps around the back and the fingers of the respective hands eventually meet and interlace.  One foot stays rooted into the earth and straightens while the opposite leg comes up with a bent knee.  Once you are standing upright extend the leg towards the sky.  The ribcage is lifted and the heart is open in the full expression of the pose.  The gaze is forward.	Expert	\N	Increases the flexibility of the spine and back and stretches the shoulders.  Strengthens the legs.  Increases flexibility of the hip and knee joints.  Improves balance.  Opens the groin.  Stretches the hamstrings.	static/img/bird_of_paradise_revolved_L.png	t	Revolved Bird of Paradise (Preparation)	Revolved Bird of Paradise (Preparation)	{"5": 1, "24": 1, "25": 1, "158": 1, "42": 1, "50": 1}	'arm':16,25 'around':19,27 'back':18,29 'bent':58 'bird':2A 'chair':10 'come':54 'dvijasana':7C 'earth':47 'eventu':37 'express':83 'extend':65 'finger':32 'foot':42 'forward':90 'full':82 'gaze':88 'hand':36 'heart':77 'interlac':40 'knee':59 'leg':21,53,67 'lift':74 'lower':15 'meet':38 'one':41 'open':79 'opposit':52 'paradis':4A 'parivrtta':5C 'parivṛtta':11 'pose':13,86 'reach':17 'respect':35 'revolv':1A,9 'ribcag':72 'root':44 'sky':70 'stand':63 'stay':43 'straighten':49 'svarga':6C 'toward':68 'upper':24 'upright':64 'utkaṭāsana':12 'wrap':26
193	Wind Removing	Pavanamuktāsana	Pavanamuktasana	From a supine position, lying on your back, the knees are bent and pulled into the chest.  The arms are wrapped around the knees with the chin tucked in towards the sternum like a turtle going into its shell.  The gaze is inward.	Beginner	\N	Releases the back and the spine.  A nice release from backbends.	static/img/turtle.png	\N	Corpse	Corpse	{"32": 1, "161": 1, "194": 1, "149": 1, "9": 1, "98": 1}	'arm':22 'around':25 'back':11 'bent':15 'chest':20 'chin':30 'gaze':44 'go':39 'inward':46 'knee':13,27 'lie':8 'like':36 'pavanamuktasana':3C 'posit':7 'pull':17 'remov':2A 'shell':42 'sternum':35 'supin':6 'toward':33 'tuck':31 'turtl':38 'wind':1A 'wrap':24
2	Balancing the Cat	Utthita Cakravākāsana	Utthita Cakravakasana	From Box (Cakravākāsana), extend one foot towards the back, knee is straight, hips squared to the floor.  Slowly extend the opposite arm forward, keep the hand and neck in line with the spine.	Intermediate	\N	Stretches the extended leg and arm.  Strengthens the hips and shoulders.  Improves flexibility and balance.	static/img/cat_balance_R.png	t	Half Bow,Box	Half Bow,Box	{"12": 1, "13": 1, "70": 1, "14": 1, "16": 1, "136": 1, "143": 1}	'arm':27 'back':14 'balanc':1A 'box':7 'cakravakasana':5C 'cakravākāsana':8 'cat':3A 'extend':9,24 'floor':22 'foot':11 'forward':28 'hand':31 'hip':18 'keep':29 'knee':15 'line':35 'neck':33 'one':10 'opposit':26 'slowli':23 'spine':38 'squar':19 'straight':17 'toward':12 'utthita':4C
194	One Legged Wind Removing	Eka Pāda Pavanamuktāsana	Eka Pada Pavanamuktasana	From a supine position lying on your back, pull one knee into the chest with the hands clasped around the bent knee to the level of pressure desired (gas trapped in the large intestine may be released in this asana).  The other leg is extended straight and the gaze is natural and forward.	Beginner	\N	Releases gas trapped in large intestine.  Stretches the cervical spine (neck).  Improves the digestion system.  Aides in elimination.	static/img/wind_removing_R.png	t	Corpse,Supine Spinal Twist	Corpse	{"32": 1, "161": 1, "193": 1, "149": 1, "9": 1, "98": 1}	'around':26 'asana':47 'back':15 'bent':28 'chest':21 'clasp':25 'desir':35 'eka':5C 'extend':52 'forward':60 'gas':36 'gaze':56 'hand':24 'intestin':41 'knee':18,29 'larg':40 'leg':2A,50 'level':32 'lie':12 'may':42 'natur':58 'one':1A,17 'pada':6C 'pavanamuktasana':7C 'posit':11 'pressur':34 'pull':16 'releas':44 'remov':4A 'straight':53 'supin':10 'trap':37 'wind':3A
27	Child's	Balāsana	Balasana	From a kneeling position, the toes and knees are together with most of the weight of the body resting on the heels of the feet.  The arms are extended back resting alongside the legs.  The forehead rests softly onto the earth.  The gaze is down and inward.	Beginner	\N	Gently stretches the hips, thighs, and ankles.  Calms the brain and helps relieve stress and fatigue.  Relieves back and neck pain when done with head and torso supported.	static/img/child_traditional.png	\N	Box	\N	{"13": 1, "28": 1, "33": 1, "148": 1, "29": 1, "30": 1, "75": 1, "179": 1}	'alongsid':34 'arm':29 'back':32 'balasana':2C 'bodi':20 'child':1A 'earth':43 'extend':31 'feet':27 'forehead':38 'gaze':45 'heel':24 'inward':49 'knee':10 'kneel':5 'leg':36 'onto':41 'posit':6 'rest':21,33,39 'soft':40 'toe':8 'togeth':12 'weight':17
17	Bridge	Setu Bandha Sarvāṅgāsana	Setu Bandha Sarvangasana	From a supine position, on your back, the hips are pressed up with the heels of the feet rooted into the earth close to the sits bones.  The toes are actively lifted and the pelvis tucked.  The thighs are parallel to the earth and the fingers are interlaced under the body with the ribcage lifted and the heart open.  The back of the neck rests on the earth.  The gaze is to the sky.	Intermediate	\N	Stretches the chest, neck, and spine.  Stimulates abdominal organs, lungs, and thyroids.  Rejuvenates tired legs.  Improves digestion.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done supported.  Reduces anxiety, fatigue, backache, headache, and insomnia.  Therapeutic for asthma, high blood pressure, osteoporosis, and sinusitis.	static/img/bridge.png	\N	One Legged Bridge,Corpse,Wheel	One Legged Bridge,Corpse	{"18": 1, "32": 1, "190": 1, "35": 1, "7": 1, "72": 1}	'activ':35 'back':11,65 'bandha':3C 'bodi':55 'bone':31 'bridg':1A 'close':27 'earth':26,47,72 'feet':22 'finger':50 'gaze':74 'heart':62 'heel':19 'hip':13 'interlac':52 'lift':36,59 'neck':68 'open':63 'parallel':44 'pelvi':39 'posit':8 'press':15 'rest':69 'ribcag':58 'root':23 'sarvangasana':4C 'setu':2C 'sit':30 'sky':78 'supin':7 'thigh':42 'toe':33 'tuck':40
29	Wide Child's	Balāsana	Balasana	From Extended Child's (Utthita Balāsana), the knees are open wide and the big toes are touching with most of the weight of the body on the heels of the feet.  The forehead rests softly onto the earth.  The arms extend to the front with the fingers spread wide.  The gaze is down and inward.	Beginner	\N	Gently stretches the hips, thighs, and ankles.  Calms the brain and helps relieve stress and fatigue.  Relieves back and neck pain when done with head and torso supported.	static/img/child_wide.png	\N	Box,Wide Child's with Side Stretch	Box,Wide Child's with Side Stretch	{"13": 1, "30": 1, "28": 1, "75": 1}	'arm':43 'balasana':3C 'balāsana':9 'big':17 'bodi':28 'child':2A,6 'earth':41 'extend':5,44 'feet':34 'finger':50 'forehead':36 'front':47 'gaze':54 'heel':31 'inward':58 'knee':11 'onto':39 'open':13 'rest':37 'soft':38 'spread':51 'toe':18 'touch':20 'utthita':8 'weight':25 'wide':1A,14,52
33	Front Corpse	\N	\N	From a prone position with the pelvis tucked under, the body is relaxed and lying facedown onto the earth.  The forehead rests softly on the earth with the arms by the side body and the palms pressed down.  The hips are squared to the earth and the knees and ankles are touching.  The tops of the feet are relaxed and the big toes are connected.  The gaze is inward and towards the earth.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Relaxes the body.  Reduces headache, fatigue and insomnia.  Helps to lower blood pressure.	static/img/corpse_front.png	\N	Bow (Preparation),Box,Cobra,Locust,Half Locust,Plank,Sphinx	Bow,Bow (Preparation),Box,Cobra,Locust,Half Locust,Plank,Sphinx	{"11": 1, "13": 1, "31": 1, "114": 1, "115": 1, "136": 1, "160": 1, "27": 1, "28": 1}	'ankl':52 'arm':31 'big':64 'bodi':13,35 'connect':67 'corps':2A 'earth':21,28,47,75 'facedown':18 'feet':59 'forehead':23 'front':1A 'gaze':69 'hip':42 'inward':71 'knee':50 'lie':17 'onto':19 'palm':38 'pelvi':9 'posit':6 'press':39 'prone':5 'relax':15,61 'rest':24 'side':34 'soft':25 'squar':44 'toe':65 'top':56 'touch':54 'toward':73 'tuck':10
83	Standing Forward Bend	Uttānāsana	Uttanasana	From a standing position, the body is folded over at the crease of the hip with the spine long.  The neck is relaxed and the crown of the head is towards the earth.  The feet are rooted into the earth with the toes actively lifted.  The spine is straight.  The ribcage is lifted.  The chest and the thighs are connected.  The sacrum lifts up toward the sky in dog tilt.  The fingertips are resting on the earth next to the toes.  The gaze is down or slightly forward.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the liver and kidneys.  Stretches the hamstrings, calves, and hips.  Strengthens the thighs and knees.  Improves digestion.  Helps relieve the symptoms of menopause.  Reduces fatigue and anxiety.  Relieves headache and insomnia.	static/img/forward_bend.png	\N	Chair,Halfway Lift,Lunge,Lunge on the Knee,Mountain with Arms Up,Standing Splits	Chair,Crescent Lunge on the Knee,Downward-Facing Dog with Bent Knees,Half Moon,Halfway Lift,Lunge,Lunge on the Knee,Mountain with Arms Up,Side Splits,Standing Splits	{"22": 1.5, "91": 2.5, "120": 1, "124": 1, "131": 2.0, "164": 1, "176": 1, "136": 1, "87": 1}	'activ':48 'bend':3A 'bodi':10 'chest':59 'connect':64 'creas':16 'crown':30 'dog':73 'earth':37,44,81 'feet':39 'fingertip':76 'fold':12 'forward':2A,92 'gaze':87 'head':33 'hip':19 'lift':49,57,67 'long':23 'neck':25 'next':82 'posit':8 'relax':27 'rest':78 'ribcag':55 'root':41 'sacrum':66 'sky':71 'slight':91 'spine':22,51 'stand':1A,7 'straight':53 'thigh':62 'tilt':74 'toe':47,85 'toward':35,69 'uttanasana':4C
43	Crescent Lunge Twist	\N	\N	The front foot of one leg is rooted on the earth with the knee directly above and tracking the ankle in a 90 degree angle.  The back leg is straight, no bend in the knee, and the weight is distributed backwards onto the toes as the back heel pushes back and down towards the earth.  The inner thighs scissor towards each other and the pelvis is tucked under with the ribcage lifted and the chin slightly tucked.  The spine is long and extended.  The heart is open.  The torso twists towards one side and the arm corresponding towards the back leg reaches towards the back.  Both arms are straight.  Wrists and the fingers are extended and spread wide.  Gaze is over the back shoulder.	Intermediate	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, belly, groins (psoas) and the muscles of the back.  Strengthens and stretches the thighs, calves and ankles.	static/img/lunge_crescent_twist_R.png	t	Crescent Lunge,Reverse Crescent Lunge Twist,Lunge	Crescent Lunge,Reverse Crescent Lunge Twist	{"37": 1, "44": 1, "120": 1, "51": 1, "182": 1, "41": 1, "49": 1}	'90':26 'angl':28 'ankl':23 'arm':99,110 'back':30,50,53,103,108,126 'backward':44 'bend':35 'chin':78 'correspond':100 'crescent':1A 'degre':27 'direct':18 'distribut':43 'earth':14,58 'extend':86,118 'finger':116 'foot':6 'front':5 'gaze':122 'heart':88 'heel':51 'inner':60 'knee':17,38 'leg':9,31,104 'lift':75 'long':84 'lung':2A 'one':8,95 'onto':45 'open':90 'pelvi':68 'push':52 'reach':105 'ribcag':74 'root':11 'scissor':62 'shoulder':127 'side':96 'slight':79 'spine':82 'spread':120 'straight':33,112 'thigh':61 'toe':47 'torso':92 'toward':56,63,94,101,106 'track':21 'tuck':70,80 'twist':3A,93 'weight':41 'wide':121 'wrist':113
92	Standing Hand to Toe	Hasta Pādāṅguṣṭhāsana	Hasta Padangusthasana	From Mountain (Tāḍāsana) pose, lift one foot, bend forward and catch the toes with the fingers.  Place the other hand on the hip to square the hip towards the front.  Slowly straighten the knee and lift the torso straight up.  Use a strap if necessary.  Gaze towards the front.	Expert	\N	Stretches the hamstrings and strengthens the legs.  Improves balance.	static/img/standing_hand_to_toe_R.png	t	Extended Standing Hand to Toe	Extended Standing Hand to Toe,Standing Head to Knee (Preparation),Standing Knee to Chest	{"93": 1, "99": 1, "113": 1, "130": 1, "175": 1}	'bend':14 'catch':17 'finger':22 'foot':13 'forward':15 'front':36,55 'gaze':52 'hand':2A,26 'hasta':5C 'hip':29,33 'knee':40 'lift':11,42 'mountain':8 'necessari':51 'one':12 'padangusthasana':6C 'place':23 'pose':10 'slowli':37 'squar':31 'stand':1A 'straight':45 'straighten':38 'strap':49 'toe':4A,19 'torso':44 'toward':34,53 'tāḍāsana':9 'use':47
99	Standing Head to Knee	Daṇḍayamana Jānushīrāsana	Dandayamana Janushirasana	From a standing position with the feet together, the weight of the body is shifted to balance on one leg.  The opposite foot is then clasped with both hands and lifted up by pulling the knee in towards the chest.  Fingers are interlaced under the sole of the foot, specifically at the arch.  Avoid placing the thumbs on the tops of the feet.  The standing leg is straight, but the knee joint is not locked.  The standing foot is rooted firmly into the earth while the weight is shifted slightly forward, closer to the ball of the foot, not the heel.  The bent knee then extends straight until it is parallel with the earth.  Maintain balance in the pose with good pranayama (breath work) and bandhas.  Keep a leveled pelvis.  It is helpful to think about extending the foot up rather than out.  Continue to lengthen the spine from the neck down to the tailbone.  Allow the shoulders to fall into their natural position away from the ears and extend the arms, maintaining the grip on the foot and straightening the leg.  Engage the muscles of the thigh for more stability.  To achieve the full extension of the pose, round the spine and drop the elbows while lowering the head to your knee.  Avoid dropping the abdominals onto your thigh.  Pull the navel up and into the spine while folding forward.  Lower the head to the knee and tuck the chin into the chest into Jalandhara bandha.  This will extend the stretch of the spine up through the neck.  The gaze is towards the knee or out in front.	Expert	\N	Improves balance.  Enhances agility.  Helps digestion.  Massages the internal organs.  Improves circulation.  Enhances memory.	static/img/standing_head_to_knee_R.png	t	Mountain	Standing Head to Knee (Preparation)	{"130": 1, "92": 1, "100": 1, "113": 1}	'abdomin':223 'achiev':199 'allow':162 'arch':59 'arm':178 'avoid':60,220 'away':171 'balanc':23,122 'ball':101 'bandha':132,253 'bent':109 'bodi':19 'breath':129 'chest':46,250 'chin':247 'clasp':32 'closer':98 'continu':150 'dandayamana':5C 'drop':210,221 'ear':174 'earth':90,120 'elbow':212 'engag':189 'extend':112,143,176,256 'extens':202 'fall':166 'feet':13,69 'finger':47 'firm':87 'fold':236 'foot':29,55,84,104,145,184 'forward':97,237 'front':275 'full':201 'gaze':267 'good':127 'grip':181 'hand':35 'head':2A,216,240 'heel':107 'help':139 'interlac':49 'jalandhara':252 'janushirasana':6C 'joint':78 'keep':133 'knee':4A,42,77,110,219,243,271 'leg':26,72,188 'lengthen':152 'level':135 'lift':37 'lock':81 'lower':214,238 'maintain':121,179 'muscl':191 'natur':169 'navel':229 'neck':157,265 'one':25 'onto':224 'opposit':28 'parallel':117 'pelvi':136 'place':61 'pose':125,205 'posit':10,170 'pranayama':128 'pull':40,227 'rather':147 'root':86 'round':206 'shift':21,95 'shoulder':164 'slight':96 'sole':52 'specif':56 'spine':154,208,234,261 'stabil':197 'stand':1A,9,71,83 'straight':74,113 'straighten':186 'stretch':258 'tailbon':161 'thigh':194,226 'think':141 'thumb':63 'togeth':14 'top':66 'toward':44,269 'tuck':245 'weight':16,93 'work':130
182	Warrior I	Vīrabhadrāsana I	Virabhadrasana I	From a standing position, the legs are in a wide stance with the feet aligned and flat on the earth.  The back foot is in a 60-degree angle towards the front.  The hips are squared.  The inner thighs are rotated towards each other.  The front knee is bent in a 90-degree angle directly above the ankle.  The arms extend up to the sky with the biceps by the ears.  The hands can be together or separated and facing each other with the fingers spread wide.  The ribcage is lifted and the pelvis tucked.  The gaze is forward.	Beginner	\N	Stretches the chest, lungs, shoulders, neck, belly and groin (psoas).  Strengthens the shoulders, arms and back muscles.  Strengthens and stretches the thighs, calves and ankles.	static/img/warrior_I_R.png	t	Four Limbed Staff,Warrior I with Hands on Hips,Warrior I with Prayer Hands,Warrior I Forward Bend,Warrior II,Warrior III	Downward-Facing Dog,Lunge,Warrior I with Hands on Hips,Warrior I with Prayer Hands,Warrior I Forward Bend,Warrior II,Warrior III	{"171": 2.0, "183": 1, "184": 1, "185": 1.5, "187": 1.5, "189": 1, "83": 1, "130": 1, "180": 1, "188": 1, "186": 1, "156": 1, "120": 1, "37": 1}	'60':29 '90':54 'align':17 'angl':31,56 'ankl':60 'arm':62 'back':24 'bent':51 'bicep':70 'degre':30,55 'direct':57 'ear':73 'earth':22 'extend':63 'face':82 'feet':16 'finger':87 'flat':19 'foot':25 'forward':101 'front':34,48 'gaze':99 'hand':75 'hip':36 'inner':40 'knee':49 'leg':8 'lift':93 'pelvi':96 'posit':6 'ribcag':91 'rotat':43 'separ':80 'sky':67 'spread':88 'squar':38 'stanc':13 'stand':5 'thigh':41 'togeth':78 'toward':32,44 'tuck':97 'virabhadrasana':2C 'warrior':1A 'wide':12,89
70	One Legged Downward-Facing Dog	Eka Pāda Adho Mukha Śvānāsana	Eka Pada Adho Mukha Svanasana	From Downward-Facing Dog (Adho Mukha Śvānāsana), one foot extends up to the sky while the opposite foot is rooted into the earth.  The hips are squared and the toes are active.  The forehead reaches for the earth as the shoulder blades rotate inward.  The gaze is towards the back.	Intermediate	\N	Tones and strengthens the standing leg.  Improves flexibility.  Opens the hips.	static/img/downward_dog_leg_up_R.png	t	Downward-Facing Dog,Downward-Facing Dog with Knee to Forehead,Downward-Facing Dog with Stacked Hips,Flying Man,Revolved Flying Man,One Legged King Pigeon (Preparation),Lunge,Lunge with Hands on the Inside of the Leg,Lunge on the Knee,One Legged Plank,One Legged Plank on the Knee,Front Splits	Downward-Facing Dog,Downward-Facing Dog with Knee to Forehead,Downward-Facing Dog with Stacked Hips,Flying Man,Revolved Flying Man,One Legged King Pigeon (Preparation),Lunge,Lunge with Hands on the Inside of the Leg,One Legged Plank,One Legged Plank on the Knee,Front Splits,Wild Thing	{"64": 1, "67": 1, "68": 1, "79": 1, "80": 1, "111": 1, "120": 1, "123": 1, "124": 1, "137": 1, "141": 1, "162": 1, "136": 1, "69": 1, "192": 1}	'activ':44 'adho':9C,17 'back':62 'blade':54 'dog':6A,16 'downward':4A,14 'downward-fac':3A,13 'earth':35,50 'eka':7C 'extend':22 'face':5A,15 'foot':21,30 'forehead':46 'gaze':58 'hip':37 'inward':56 'leg':2A 'mukha':10C,18 'one':1A,20 'opposit':29 'pada':8C 'reach':47 'root':32 'rotat':55 'shoulder':53 'sky':26 'squar':39 'svanasana':11C 'toe':42 'toward':60 'śvānāsana':19
60	Dolphin	\N	\N	From Downward-Facing Dog (Adho Mukha Śvānāsana), the forearms are planted onto the earth with the elbows narrow and the palms down in a Sphinx (Sālamba Bhujaṅgāsana) position.  The pelvis is tucked.  The ribcage lifted.  The feet are rooted and the legs are straight with the tailbone in dog tilt.  The gaze is down and slightly forward	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.  Warms up the ankles and the toes.	static/img/dolphin.png	\N	One Legged Dolphin,Feathered Peacock,Side Splits	Box,One Legged Dolphin,Feathered Peacock	{"61": 1, "132": 1, "163": 1, "62": 1, "63": 1, "64": 1, "101": 1}	'adho':7 'bhujaṅgāsana':29 'dog':6,51 'dolphin':1A 'downward':4 'downward-fac':3 'earth':16 'elbow':19 'face':5 'feet':39 'forearm':11 'forward':59 'gaze':54 'leg':44 'lift':37 'mukha':8 'narrow':20 'onto':14 'palm':23 'pelvi':32 'plant':13 'posit':30 'ribcag':36 'root':41 'slight':58 'sphinx':27 'straight':46 'sālamba':28 'tailbon':49 'tilt':52 'tuck':34 'śvānāsana':9
52	Reverse Crescent Lunge Twist on the Knee	\N	\N	The front foot of one leg is rooted on the earth with the knee directly above and tracking the ankle in a 90 degree angle.  The knee of the back leg is down on the earth.  The inner thighs scissor towards each other and the pelvis is tucked under with the ribcage lifted and the chin slightly tucked.  The spine is long and extended.  The heart is open.  The arm corresponding to the front leg reaches back and touches the thigh of the back leg.  The other arm extends upwards towards the sky and slightly towards the back.	Intermediate	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, belly, groins (psoas) and the muscles of the back.  Strengthens and stretches the thighs, calves and ankles.	static/img/lunge_crescent_kneeling_twist_reverse_R.png	t	Crescent Lunge Twist on the Knee	Crescent Lunge Twist on the Knee	{"51": 1, "45": 1, "147": 1, "46": 1, "47": 1, "124": 1}	'90':30 'angl':32 'ankl':27 'arm':77,95 'back':37,84,91,105 'chin':63 'correspond':78 'crescent':2A 'degre':31 'direct':22 'earth':18,43 'extend':71,96 'foot':10 'front':9,81 'heart':73 'inner':45 'knee':7A,21,34 'leg':13,38,82,92 'lift':60 'long':69 'lung':3A 'one':12 'open':75 'pelvi':53 'reach':83 'revers':1A 'ribcag':59 'root':15 'scissor':47 'sky':100 'slight':64,102 'spine':67 'thigh':46,88 'touch':86 'toward':48,98,103 'track':25 'tuck':55,65 'twist':4A 'upward':97
101	Supported Headstand	Sālamba Śīrṣāsana I	Salamba Sirsasana I	In this inverted posture, the weight of the body is evenly balanced on the forearms that are narrow.  The fingers are interlaced (pinky fingers spooning).  The crown of the head is resting softly on the earth (only to regulate balance) between the interlaced fingers hugging the head in order to stabilize and protect the neck.  The shoulder blades are pressed against the back to widen the back as the tailbone continues to lift upward toward the heels.  The gaze is straight.	Expert	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the pituitary and pineal glands.  Strengthens the arms, legs, and spine.  Strengthens the lungs.  Tones the abdominal organs.  Improves digestion.  Helps relieve the symptoms of menopause.  Therapeutic for asthma, infertility, insomnia, and sinusi.	static/img/headstand_supported.png	\N	\N	Supported Headstand (Preparation)	{"60": 1, "64": 1, "107": 1, "13": 1}	'back':67,71 'balanc':16,44 'blade':62 'bodi':13 'continu':75 'crown':31 'earth':40 'even':15 'finger':24,28,48 'forearm':19 'gaze':83 'head':34,51 'headstand':2A 'heel':81 'hug':49 'interlac':26,47 'invert':7 'lift':77 'narrow':22 'neck':59 'order':53 'pinki':27 'postur':8 'press':64 'protect':57 'regul':43 'rest':36 'salamba':3C 'shoulder':61 'sirsasana':4C 'soft':37 'spoon':29 'stabil':55 'straight':85 'support':1A 'tailbon':74 'toward':79 'upward':78 'weight':10 'widen':69
103	Tripod Headstand	Sālamba Śīrṣāsana II	Salamba Sirsasana II	The body is inverted and perpendicular to the earth with the legs extended up.  The weight of the body is balanced between the crown of the head and the palms of the hands with the elbows bent in a 90- degree angle and the fingers forward.  The head and hands are spaced equally forming an equilateral triangle.  The neck is a natural extension of the spine.  The chin is tucked slightly in towards the sternum.  The toes are active and feet reach straight up toward the sky.  The gaze is straight.	Expert	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the pituitary and pineal glands.  Strengthens the arms, legs, and spine.  Strengthens the lungs.  Tones the abdominal organs.  Improves digestion.  Helps relieve the symptoms of menopause.  Therapeutic for asthma, infertility, insomnia, and sinusitis.	static/img/headstand_tripod.png	\N	Downward-Facing Dog,Tripod Headstand with Knees on Elbows,Tripod Headstand - Spiral the Legs	Downward-Facing Dog,Tripod Headstand with Knees on Elbows,Tripod Headstand - Spiral the Legs	{"64": 1, "105": 1, "106": 1, "60": 1, "83": 1}	'90':45 'activ':84 'angl':47 'balanc':26 'bent':42 'bodi':7,24 'chin':73 'crown':29 'degre':46 'earth':14 'elbow':41 'equal':58 'equilater':61 'extend':18 'extens':68 'feet':86 'finger':50 'form':59 'forward':51 'gaze':94 'hand':38,55 'head':32,53 'headstand':2A 'ii':5C 'invert':9 'leg':17 'natur':67 'neck':64 'palm':35 'perpendicular':11 'reach':87 'salamba':3C 'sirsasana':4C 'sky':92 'slight':76 'space':57 'spine':71 'sternum':80 'straight':88,96 'toe':82 'toward':78,90 'triangl':62 'tripod':1A 'tuck':75 'weight':21
186	Warrior I Forward Bend with Hands on Hips	\N	\N	From a standing position, the legs are in a wide stance with the feet aligned and flat on the earth.  The back foot is in a 60-degree angle towards the front.  The hips are squared.  The inner thighs are rotated towards each other.  The front knee is bent in a 90-degree angle directly above the ankle.  The ribcage is lifted.  The hands are resting on the hips.  The shoulder blades are back and down, squeezing together.  The lower body stays static.  The upper torso gently bends forward from the crease of the hip with a straight line.  The gaze is forward.	Beginner	\N	Stretches the chest, lungs, neck, belly and groin (psoas).  Strengthens the back muscles.  Strengthens and stretches the thighs, calves and ankles.	static/img/warrior_I_hands_on_hips_forward_R.png	t	Warrior I with Hands on Hips	Warrior I with Hands on Hips	{"183": 1, "185": 1, "182": 1}	'60':35 '90':60 'align':23 'angl':37,62 'ankl':66 'back':30,82 'bend':4A,96 'bent':57 'blade':80 'bodi':89 'creas':100 'degre':36,61 'direct':63 'earth':28 'feet':22 'flat':25 'foot':31 'forward':3A,97,111 'front':40,54 'gaze':109 'gentl':95 'hand':6A,72 'hip':8A,42,77,103 'inner':46 'knee':55 'leg':14 'lift':70 'line':107 'lower':88 'posit':12 'rest':74 'ribcag':68 'rotat':49 'shoulder':79 'squar':44 'squeez':85 'stanc':19 'stand':11 'static':91 'stay':90 'straight':106 'thigh':47 'togeth':86 'torso':94 'toward':38,50 'upper':93 'warrior':1A 'wide':18
190	Wheel	Ūrdhva Dhanurāsana	Urdhva Dhanurasana	Pressed up from a supine position, lying on your back, the palms are rooted into the earth with the fingers pointed towards the heels.  The feet are grounded.  The hips are pressed up.  The thighs are rotated inward.  The thoracic spine is arched creating a strong crescent arch along the spinal column.  The gaze is forward.	Expert	\N	Strengthens the arms, wrists, legs, buttocks, abs, and spine.  Stimulates the thyroid and pituitary.  Increases energy and counteracts depression.  Therapeutic for asthma, back pain, infertility, and osteoporosis.	static/img/wheel.png	\N	Corpse,One Legged Wheel	Bridge,Corpse,One Legged Wheel	{"32": 1, "191": 1, "170": 1, "17": 1}	'along':52 'arch':46,51 'back':13 'column':55 'creat':47 'crescent':50 'dhanurasana':3C 'earth':20 'feet':29 'finger':23 'forward':59 'gaze':57 'ground':31 'heel':27 'hip':33 'inward':41 'lie':10 'palm':15 'point':24 'posit':9 'press':4,35 'root':17 'rotat':40 'spinal':54 'spine':44 'strong':49 'supin':8 'thigh':38 'thorac':43 'toward':25 'urdhva':2C 'wheel':1A
94	Supine Hand to Toe	Supta Hasta Pādāṅguṣṭhāsana	Supta Hasta Padangusthasana	In supine position, raise one leg to the sky.  Using the hand from the same side, catch the toes to bring the knee closer to the chest, straightening the knee.  Make sure the gluts and the other legs are rested on the floor.  If the hand cannot reach the toes, use a strap.	Intermediate	\N	Stretches the hamstrings and strengthens the leg.	static/img/supine_hand_to_toe_R.png	t	Corpse,Extended Supine Hand to Toe	Corpse	{"32": 1, "95": 1, "83": 1, "98": 1, "135": 1, "161": 1, "194": 1}	'bring':28 'cannot':54 'catch':24 'chest':34 'closer':31 'floor':50 'glut':41 'hand':2A,19,53 'hasta':6C 'knee':30,37 'leg':13,45 'make':38 'one':12 'padangusthasana':7C 'posit':10 'rais':11 'reach':55 'rest':47 'side':23 'sky':16 'straighten':35 'strap':60 'supin':1A,9 'supta':5C 'sure':39 'toe':4A,26,57 'use':17,58
95	Extended Supine Hand to Toe	Utthita Supta Hasta Pādāṅguṣṭhāsana	Utthita Supta Hasta Padangusthasana	From Supine Hand to Toe (Supta Hasta Pādāṅguṣṭhāsana) pose, drop the extended leg to one side, opening the hip.  Keep the knee straight and if necessary use a strap.  Place the opposite hand on the pelvic bone to prevent the glut from lifting off the floor.  Keep the gluts grounded.	Intermediate	\N	Opens the hips and groins.  Stretches the hamstrings, IT bands and legs	static/img/supine_hand_to_toe_extended_R.png	t	Corpse	Supine Hand to Toe	{"32": 1, "94": 1}	'bone':46 'drop':19 'extend':1A,21 'floor':55 'glut':50,58 'ground':59 'hand':3A,12,42 'hasta':8C,16 'hip':28 'keep':29,56 'knee':31 'leg':22 'lift':52 'necessari':35 'one':24 'open':26 'opposit':41 'padangusthasana':9C 'pelvic':45 'place':39 'pose':18 'prevent':48 'pādāṅguṣṭhāsana':17 'side':25 'straight':32 'strap':38 'supin':2A,11 'supta':7C,15 'toe':5A,14 'use':36 'utthita':6C
90	Revolved Half Moon	Parivṛtta Ardha Chandrāsana	Parivrtta Ardha Chandrasana	From Half Moon (Ardha Chandrāsana), slowly bring the top hand down to replace the bottom hand.  On the next inhalation, bring the opposite hand to the sky, twist the pelvis to the opposite side and stack the shoulders on top of each other.  Gaze is towards the sky and if not possible, gaze is downwards.	Intermediate	\N	Strengthens the abdomen, ankles, thighs, buttocks and spine.  Stretches the groins, hamstrings, calves, shoulders, chest and spine.  Improves coordination and sense of balance.	static/img/half_moon_revolved_R.png	t	Standing Splits	Standing Splits,Revolved Triangle	{"164": 1, "64": 1, "83": 1, "88": 1, "189": 1, "178": 1}	'ardha':5C,10 'bottom':21 'bring':13,27 'chandrasana':6C 'chandrāsana':11 'downward':61 'gaze':50,59 'half':2A,8 'hand':16,22,30 'inhal':26 'moon':3A,9 'next':25 'opposit':29,39 'parivrtta':4C 'pelvi':36 'possibl':58 'replac':19 'revolv':1A 'shoulder':44 'side':40 'sky':33,54 'slowli':12 'stack':42 'top':15,46 'toward':52 'twist':34
108	Supine Hero	Supta Vīrāsana	Supta Virasana	From a reclined supine position with the lower back pressed to the earth, the knees are bent and the feet are pulled into the side body with arm straight and palms up.  The heads of the thighbones sink deep into the back of the hip sockets.  The knees may lift a little away from the floor to help soften your groins; in fact, you can raise your knees a few inches on a thickly folded blanket.  You can also allow a little bit of space between your knees as long as your thighs remain parallel to each other.  Do not allow the knees to splay wider than your hips as this will cause strain on the hips and lower back.  The gaze is soft and up.	Intermediate	\N	Stretches the abdomen, thighs and deep hip flexors (psoas), knees, and ankles.  Strengthens the arches.  Relieves tired legs.  Improves digestion.  Helps relieves the symptoms of menstrual pain.	static/img/hero_reclining.png	\N	Hero,Extended Supine Hero	Hero	{"107": 1, "109": 1, "32": 1, "17": 1, "9": 1}	'allow':84,105 'also':83 'arm':32 'away':57 'back':13,46,124 'bent':21 'bit':87 'blanket':80 'bodi':30 'caus':117 'deep':43 'earth':17 'fact':67 'feet':24 'floor':60 'fold':79 'gaze':126 'groin':65 'head':38 'help':62 'hero':2A 'hip':49,113,121 'inch':75 'knee':19,52,72,92,107 'lift':54 'littl':56,86 'long':94 'lower':12,123 'may':53 'palm':35 'parallel':99 'posit':9 'press':14 'pull':26 'rais':70 'reclin':7 'remain':98 'side':29 'sink':42 'socket':50 'soft':128 'soften':63 'space':89 'splay':109 'straight':33 'strain':118 'supin':1A,8 'supta':3C 'thick':78 'thigh':97 'thighbon':41 'virasana':4C 'wider':110
104	Tripod Headstand (Preparation)	\N	\N	From a standing position, the body is folded forward from a wide stance.  The elbows are bent in a 90-degree angle and the fingers are in line with the toes.  The palms are flat and the knuckles are evenly pressed into the earth.  The crown of the head is resting on the earth slightly in front of the hands forming an equilateral triangle.  The neck is a natural extension of the spine.  The chin is slightly tucked in towards the sternum.	Beginner	\N	Calms the brain and helps relieve stress and mild depression.  Stimulates the pituitary and pineal glands.  Strengthens the arms, legs and spine.  Strengthens the lungs.  Tones the abdominal organs.  Improves digestion.  Helps relieve the symptoms of menopause.  Therapeutic for asthma, infertility, insomnia and sinusitis.	static/img/headstand_tripod_preparation.png	\N	Tripod Headstand with Knees on Elbows	Side Splits	{"105": 1, "83": 1}	'90':23 'angl':25 'bent':20 'bodi':9 'chin':78 'crown':49 'degre':24 'earth':47,57 'elbow':18 'equilater':66 'even':43 'extens':73 'finger':28 'flat':38 'fold':11 'form':64 'forward':12 'front':60 'hand':63 'head':52 'headstand':2A 'knuckl':41 'line':31 'natur':72 'neck':69 'palm':36 'posit':7 'prepar':3A 'press':44 'rest':54 'slight':58,80 'spine':76 'stanc':16 'stand':6 'sternum':85 'toe':34 'toward':83 'triangl':67 'tripod':1A 'tuck':81 'wide':15
109	Extended Supine Hero	Utthita Supta Vīrāsana	Utthita Supta Virasana	Start from Hero (Vīrāsana) pose and slowly transition to Supine Hero (Supta Vīrāsana) pose.  Bring the hands back and straighten the arms with palms facing up.  Roll a blanket underneath the back if needed.	Intermediate	\N	Stretches the abdomen, shoulders, arms and thighs including hip flexors.  Strengthens the back muscles, ankles and knees.  Stimulates the abdominal organs, kidneys, lungs and rib cage.	static/img/hero_reclining_extended.png	\N	Hero	Supine Hero	{"107": 1, "108": 1, "32": 1, "17": 1}	'arm':28 'back':24,38 'blanket':35 'bring':21 'extend':1A 'face':31 'hand':23 'hero':3A,9,17 'need':40 'palm':30 'pose':11,20 'roll':33 'slowli':13 'start':7 'straighten':26 'supin':2A,16 'supta':5C,18 'transit':14 'underneath':36 'utthita':4C 'virasana':6C 'vīrāsana':10,19
143	Plank on the Knees	\N	\N	The body is parallel to the earth.  The weight of the body is supported by straight arms and the top of the squared knees.  The abdomen is pulled up towards the spine.  The pelvis is tucked.  The neck is a natural extension of the spine and the chin is slightly tucked in.  The palms are flat and the elbows are close to the side body.  The joints are stacked with the wrists, elbows and shoulders in a straight line perpendicular to the earth.  The gaze is down following the straight line of the spine.	Beginner	\N	Strengthens the arms, wrists, and spine.  Tones the abdomen.	static/img/plank_kneeling.png	\N	Side Plank on the Knee,Four Limbed Staff	Downward-Facing Dog,Halfway Lift,Side Plank on the Knee,Warrior II	{"142": 1, "171": 1, "136": 1, "124": 1, "127": 1, "13": 1, "141": 1, "64": 1}	'abdomen':30 'arm':21 'bodi':6,16,69 'chin':52 'close':65 'earth':11,87 'elbow':63,77 'extens':46 'flat':60 'follow':92 'gaze':89 'joint':71 'knee':4A,28 'line':83,95 'natur':45 'neck':42 'palm':58 'parallel':8 'pelvi':38 'perpendicular':84 'plank':1A 'pull':32 'shoulder':79 'side':68 'slight':54 'spine':36,49,98 'squar':27 'stack':73 'straight':20,82,94 'support':18 'top':24 'toward':34 'tuck':40,55 'weight':13 'wrist':76
126	Lunge on the Knee with Arm Extended Up	\N	\N	From Lunge on the Knee, the arm corresponding to the bent knee extends to the sky as the torso rotates open.  The palm is open out and the fingers are spread wide.  The other arm (which is in the same plane as the top arm) remains on the inside of the thigh with the palm rooted to the earth for balance.  The gaze is up towards the sky, unless it hurts your neck, then take the gaze to the earth.	Beginner	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Opens the shoulders.	static/img/lunge_kneeling_arm_up_R.png	t	Lunge on the Knee	Lunge on the Knee with Arm Extended Forward	{"124": 1, "125": 1}	'arm':6A,14,42,52 'balanc':68 'bent':18 'correspond':15 'earth':66,87 'extend':7A,20 'finger':36 'gaze':70,84 'hurt':78 'insid':56 'knee':4A,12,19 'lung':1A,9 'neck':80 'open':28,32 'palm':30,62 'plane':48 'remain':53 'root':63 'rotat':27 'sky':23,75 'spread':38 'take':82 'thigh':59 'top':51 'torso':26 'toward':73 'unless':76 'wide':39
112	One Legged King Pigeon - Mermaid	Eka Pāda Rājakapotāsana	Eka Pada Rajakapotasana	From a seated position with the hips squared, one leg is extended forward with the knee bent and parallel to the earth.  The front heel is rooted close to the groin (or extended out in a 90 degree angle if flexibility allows).  The other leg is extended back with the knee bent and perpendicular to the earth.  The back foot is hooked on the inside of the elbow of the back arm.  The front elbow is bent upward perpendicular to the earth with the bicep by the ear.  The fingers are interlaced to connect the bind behind the body and assist in opening the chest.  The gaze is natural and forward.	Intermediate	\N	Stretches the thighs, groins (psoas), abdomen, chest, shoulders and neck.  Stimulates the abdominal organs.  Opens the shoulders and chest.	static/img/pigeon_full_R.png	t	Cow Face (Preparation),One Legged King Pigeon	One Legged King Pigeon (Preparation)	{"36": 1, "110": 1, "111": 1, "159": 1}	'90':45 'allow':50 'angl':47 'arm':80 'assist':109 'back':56,67,79 'behind':105 'bent':25,60,85 'bicep':93 'bind':104 'bodi':107 'chest':113 'close':36 'connect':102 'degre':46 'ear':96 'earth':30,65,90 'eka':6C 'elbow':76,83 'extend':20,41,55 'finger':98 'flexibl':49 'foot':68 'forward':21,119 'front':32,82 'gaze':115 'groin':39 'heel':33 'hip':15 'hook':70 'insid':73 'interlac':100 'king':3A 'knee':24,59 'leg':2A,18,53 'mermaid':5A 'natur':117 'one':1A,17 'open':111 'pada':7C 'parallel':27 'perpendicular':62,87 'pigeon':4A 'posit':12 'rajakapotasana':8C 'root':35 'seat':11 'squar':16 'upward':86
129	Marichi's III	Marīchyāsana III	Marichyasana III	From a seated position, one leg is extended to the front.  The opposite knee is bent and perpendicular to the earth at a 90-degree angle with the heel close to the groin.  The inside arm is extended towards the front with the palm turned outward in the opposite direction to facilitate the hinge of the elbow which is then wrapped around the bent knee from inside of the thigh.  The other arm is wrapped around the opposite side of the body.  Retaining a long lifted spine, the upper torso twists towards the back.  The hands meet and bind at the lower back.  The fingers are interlaced.  The ribcage is lifted and the heart is open.  The gaze follows the spine as it twists open.	Intermediate	\N	Massages abdominal organs, including the liver and kidneys.  Stretches the shoulders.  Stimulates the brain.  Relieves mild backache and hip pain.  Strengthens and stretches the spine.	static/img/marichi_III_L.png	t	Box,Staff	Marichi's I,Staff	{"13": 1, "169": 1, "128": 1, "81": 1}	'90':29 'angl':31 'arm':41,78 'around':67,81 'back':99,108 'bent':21,69 'bind':104 'bodi':87 'close':35 'degre':30 'direct':55 'earth':26 'elbow':62 'extend':13,43 'facilit':57 'finger':110 'follow':124 'front':16,46 'gaze':123 'groin':38 'hand':101 'heart':119 'heel':34 'hing':59 'iii':3A,5C 'insid':40,72 'interlac':112 'knee':19,70 'leg':11 'lift':91,116 'long':90 'lower':107 'marichi':1A 'marichyasana':4C 'meet':102 'one':10 'open':121,130 'opposit':18,54,83 'outward':51 'palm':49 'perpendicular':23 'posit':9 'retain':88 'ribcag':114 'seat':8 'side':84 'spine':92,126 'thigh':75 'torso':95 'toward':44,97 'turn':50 'twist':96,129 'upper':94 'wrap':66,80
149	Rejuvenation	Supta Daṇḍāsana	Supta Dandasana	From a supine position, with the back relaxed onto the earth, the legs extend toward the sky without any tension behind the knees.  The arms rest by the side body and the palms open toward the sky in a receptive mode.  Hold this position or gently sway the legs from side to side.  The eyes are closed and the gaze is inward.	Beginner	\N	Releases spine and lower back and heals the body.	static/img/corpse_double_leg_raise.png	\N	Corpse,Supported Shoulder Stand	Corpse	{"32": 1, "153": 1, "9": 1, "94": 1, "98": 1, "135": 1, "161": 1, "193": 1, "194": 1, "169": 1}	'arm':28 'back':10 'behind':24 'bodi':33 'close':60 'dandasana':3C 'earth':14 'extend':17 'eye':58 'gaze':63 'gentl':49 'hold':45 'inward':65 'knee':26 'leg':16,52 'mode':44 'onto':12 'open':37 'palm':36 'posit':7,47 'recept':43 'rejuven':1A 'relax':11 'rest':29 'side':32,54,56 'sky':20,40 'supin':6 'supta':2C 'sway':50 'tension':23 'toward':18,38 'without':21
144	Plow	Halāsana	Halasana	From a supine position, the upper back rests on the earth with the hips and legs revolved back over the torso above and beyond the head towards the earth.  The torso is perpendicular to the earth.  The legs are fully extended with no bend at the knees as the toes reach for the earth.  The hands are either supporting the lower back or extended behind the back on the earth with extended elbows and fingers interlaced (as flexibility allows), opening the shoulders.  The neck is straight.  The chin tucked.  Do not look to the side as this may injure the neck.  The is gaze inward.	Intermediate	\N	Calms the brain.  Stimulates the abdominal organs and the thyroid glands.  Stretches the shoulders and spine.  Helps relieve the symptoms of menopause.  Reduces stress and fatigue.  Therapeutic for backache, headache, infertility, insomnia,  and sinusitis.	static/img/plow.png	\N	Corpse,Deaf Man's	Supported Shoulder Stand,Unsupported Shoulder Stand	{"32": 1, "59": 1, "153": 1, "154": 1, "149": 1}	'allow':81 'back':9,20,64,69 'behind':67 'bend':46 'beyond':26 'chin':90 'earth':13,31,38,56,72 'either':60 'elbow':75 'extend':43,66,74 'finger':77 'flexibl':80 'fulli':42 'gaze':106 'halasana':2C 'hand':58 'head':28 'hip':16 'injur':101 'interlac':78 'inward':107 'knee':49 'leg':18,40 'look':94 'lower':63 'may':100 'neck':86,103 'open':82 'perpendicular':35 'plow':1A 'posit':6 'reach':53 'rest':10 'revolv':19 'shoulder':84 'side':97 'straight':88 'supin':5 'support':61 'toe':52 'torso':23,33 'toward':29 'tuck':91 'upper':8
163	Side Splits	Upaviṣṭha Koṇāsana	Upavistha Konasana	From a wide stance the legs are open and extended sideways to your degree of flexibility.  The outer edges of the feet are rotated and gripping toward the earth.  The weight of the body is supported by the arms.  The palms are rooted into the earth with the fingers pointing towards the body.  There should be no excess weight on the knee or ankle joints as you lower down to your degree of flexibility.  The gaze is down and slightly forward.	Expert	\N	Stretches the insides and backs of the legs.  Stimulates the abdominal organs.  Strengthens the spine.  Calms the brain.  Releases groin.	static/img/splits_wide.png	\N	Box,Standing Forward Bend,Tripod Headstand (Preparation),Tortoise (Preparation)	Dolphin,Downward-Facing Dog,Firefly,Tripod Headstand with Knees on Elbows,Scale,Tortoise (Preparation)	{"13": 1, "83": 1, "104": 1, "174": 1, "135": 1, "169": 1}	'ankl':68 'arm':43 'bodi':38,57 'degre':18,76 'earth':33,50 'edg':23 'excess':62 'extend':14 'feet':26 'finger':53 'flexibl':20,78 'forward':85 'gaze':80 'grip':30 'joint':69 'knee':66 'konasana':4C 'leg':10 'lower':72 'open':12 'outer':22 'palm':45 'point':54 'root':47 'rotat':28 'side':1A 'sideway':15 'slight':84 'split':2A 'stanc':8 'support':40 'toward':31,55 'upavistha':3C 'weight':35,63 'wide':7
174	Tortoise (Preparation)	\N	\N	The feet are hips width apart and the body is in a forward bend position with the torso folded forward at the crease of the hips.  The crown of the head is towards the earth.  The hands and the elbows wrap around the inside of the thighs and catch the ankles in preparation for Tortoise (Kūrmāsana) pose.  The gaze is down.	Intermediate	\N	Stretches the insides and backs of the legs.  Stimulates the abdominal organs.  Strengthens the spine.  Calms the brain.  Releases groin.  Releases the elbows.	static/img/tortoise.png	\N	Scale,Side Splits,Tortoise	Side Splits	{"150": 1, "163": 1, "173": 1, "86": 1}	'ankl':53 'apart':8 'around':44 'bend':16 'bodi':11 'catch':51 'creas':25 'crown':30 'earth':37 'elbow':42 'feet':4 'fold':21 'forward':15,22 'gaze':61 'hand':39 'head':33 'hip':6,28 'insid':46 'kūrmāsana':58 'pose':59 'posit':17 'prepar':2A,55 'thigh':49 'torso':20 'tortois':1A,57 'toward':35 'width':7 'wrap':43
141	One Legged Plank on the Knee	\N	\N	The body is parallel to the earth, and supported by straight arms and one knee.  The other leg is extended off the earth and reaches back with active toes.  The abdomen is pulled up towards the spine.  The pelvis is tucked.  The neck is a natural extension of the spine.  The chin is slightly tucked.  The palms are flat and the elbows are close to the side body.  The joints are stacked with the wrists, elbows and shoulders in a straight line perpendicular to the earth.  The gaze follows the spine and the eyes are focused down towards the earth.	Beginner	\N	Strengthens the arms, wrists and spine.  Tones the abdomen.	static/img/plank_leg_up_kneeling_R.png	t	Box with Knee to Forehead,One Legged Box,One Legged Downward-Facing Dog	Box with Knee to Forehead,One Legged Box,One Legged Downward-Facing Dog	{"14": 1, "16": 1, "70": 1, "13": 1}	'abdomen':37 'activ':34 'arm':18 'back':32 'bodi':8,74 'chin':58 'close':70 'earth':13,29,92,106 'elbow':68,82 'extend':26 'extens':53 'eye':100 'flat':65 'focus':102 'follow':95 'gaze':94 'joint':76 'knee':6A,21 'leg':2A,24 'line':88 'natur':52 'neck':49 'one':1A,20 'palm':63 'parallel':10 'pelvi':45 'perpendicular':89 'plank':3A 'pull':39 'reach':31 'shoulder':84 'side':73 'slight':60 'spine':43,56,97 'stack':78 'straight':17,87 'support':15 'toe':35 'toward':41,104 'tuck':47,61 'wrist':81
169	Staff	Daṇḍāsana	Dandasana	From a seated position both legs are extended to the front.  The torso does not lean backward.  The weight of the body is positioned towards the front of the sitting bones and the pubis and tailbone are equidistant from the earth.  Both thighs are pressed down against the floor and are rotated slightly towards each other.  The inner groins are drawn up toward the sacrum.  Feet are flexed and the toes are separated.  The heels may come up off the earth.  The ankles are pressed out through the heels.  The shoulders are stacked in line with the hips.  The arms are resting by the side body.  The front torso is lengthened perpendicular to the earth, extending up through the crown of the head towards the sky while the sits bones are rooted down.	Beginner	\N	Strengthens the back muscles.  Stretches the shoulders and chest.  Improves posture.	static/img/staff.png	\N	Marichi's I,Marichi's III,Table	Marichi's I,Marichi's III,Upward Plank,Table	{"128": 1, "129": 1, "172": 1, "81": 1, "13": 1, "140": 1, "162": 1, "21": 1, "8": 1, "36": 1, "73": 1, "82": 1, "118": 1, "119": 1, "163": 1}	'ankl':85 'arm':102 'backward':19 'bodi':24,108 'bone':33,132 'come':79 'crown':122 'dandasana':2C 'drawn':63 'earth':43,83,117 'equidist':40 'extend':10,118 'feet':68 'flex':70 'floor':51 'front':13,29,110 'groin':61 'head':125 'heel':77,91 'hip':100 'inner':60 'lean':18 'leg':8 'lengthen':113 'line':97 'may':78 'perpendicular':114 'posit':6,26 'press':47,87 'pubi':36 'rest':104 'root':134 'rotat':54 'sacrum':67 'seat':5 'separ':75 'shoulder':93 'side':107 'sit':32,131 'sky':128 'slight':55 'stack':95 'staff':1A 'tailbon':38 'thigh':45 'toe':73 'torso':15,111 'toward':27,56,65,126 'weight':21
185	Warrior I Forward Bend	\N	\N	From a standing position, the legs are in a wide stance with the feet aligned and flat on the earth.  The back foot is in a 60-degree angle towards the front.  The hips are squared.  The inner thighs are rotated inward towards each other.  The front knee is bent in a 90-degree angle directly above the ankle.  The pelvis is tucked.  The ribcage is lifted.  The shoulder blades are back and down, squeezing together.  The hands can be together or separated and facing each other with the fingers spread wide.  The lower body stays static.  The upper torso gently bends forward from the crease of the hip with a straight line.  The gaze is forward.	Intermediate	\N	Stretches the chest, lungs, neck, belly and groin (psoas).  Strengthens the shoulders, arms and back muscles.  Strengthens and stretches the thighs, calves and ankles.	static/img/warrior_I_forward_R.png	t	Warrior I,Warrior III	Warrior I	{"182": 1, "189": 1, "187": 1, "186": 1}	'60':31 '90':57 'align':19 'angl':33,59 'ankl':63 'back':26,76 'bend':4A,106 'bent':54 'blade':74 'bodi':99 'creas':110 'degre':32,58 'direct':60 'earth':24 'face':89 'feet':18 'finger':94 'flat':21 'foot':27 'forward':3A,107,121 'front':36,51 'gaze':119 'gentl':105 'hand':82 'hip':38,113 'inner':42 'inward':46 'knee':52 'leg':10 'lift':71 'line':117 'lower':98 'pelvi':65 'posit':8 'ribcag':69 'rotat':45 'separ':87 'shoulder':73 'spread':95 'squar':40 'squeez':79 'stanc':15 'stand':7 'static':101 'stay':100 'straight':116 'thigh':43 'togeth':80,85 'torso':104 'toward':34,47 'tuck':67 'upper':103 'warrior':1A 'wide':14,96
187	Warrior II	Vīrabhadrāsana II	Virabhadrasana II	From a standing position, the legs are separated into a wide stance.  The front knee is bent in a 90-degree angle directly above the ankle.  The back leg is extended and straight with the outside edge of the back foot gripping the earth in a 60-degree angle towards the front.  The inner thighs are externally rotated away from each other.  The pelvis is tucked.  The ribcage is lifted.  The arms are extended out to the sides and are aligned with the shoulders in a straight line with the fingers reaching out as the shoulder blades squeeze together.  The gaze is toward the front fingers.	Beginner	\N	Strengthens and stretches the legs and ankles.  Stretches the groin, chest, lungs, and shoulders.  Stimulates abdominal organs.  Increases stamina.  Relieves backaches, especially through second trimester of pregnancy.  Therapeutic for carpal tunnel syndrome, flat feet, infertility, osteoporosis, and sciatica.	static/img/warrior_II_R.png	t	Half Moon,Lunge,Lunge on the Knee,Plank,Plank on the Knees,Four Limbed Staff,Triangle (Preparation),Reverse Warrior,Warrior I,Warrior I with Prayer Hands,Warrior II Forward Bend	Half Moon,Triangle (Preparation),Reverse Warrior,Warrior I,Warrior I with Hands on Hips,Warrior I with Prayer Hands,Warrior II Forward Bend	{"88": 1, "120": 1, "124": 1, "136": 1, "143": 1, "171": 1, "177": 1, "180": 2.0, "182": 1, "184": 1, "188": 1, "156": 1, "37": 1}	'60':51 '90':24 'align':85 'angl':26,53 'ankl':30 'arm':76 'away':63 'back':32,44 'bent':21 'blade':101 'degre':25,52 'direct':27 'earth':48 'edg':41 'extend':35,78 'extern':61 'finger':95,110 'foot':45 'front':18,56,109 'gaze':105 'grip':46 'ii':2A,4C 'inner':58 'knee':19 'leg':10,33 'lift':74 'line':92 'outsid':40 'pelvi':68 'posit':8 'reach':96 'ribcag':72 'rotat':62 'separ':12 'shoulder':88,100 'side':82 'squeez':102 'stanc':16 'stand':7 'straight':37,91 'thigh':59 'togeth':103 'toward':54,107 'tuck':70 'virabhadrasana':3C 'warrior':1A 'wide':15
189	Warrior III	Vīrabhadrāsana III	Virabhadrasana III	From a standing position, one leg is rooted and perpendicular to the earth while the other leg is raised, extended back and parallel to the earth.  The head of the thighbone of the standing leg presses back towards the heel and is actively rooted into the earth.  The arms and the extended leg lengthen in opposing directions with Bandhas engaged.  The hips are squared and the tailbone presses firmly into the pelvis.  The arms, torso, and extended raised leg should be positioned relatively parallel to the floor.  The gaze is forward or down.	Expert	\N	Strengthens the ankles and legs.  Strengthens the shoulders and muscles of the back.  Tones the abdomen.  Improves balance and posture.	static/img/warrior_III_R.png	t	Crescent Lunge,Half Moon,Warrior I	Crescent Lunge,Warrior I,Warrior I Forward Bend	{"37": 1, "88": 1, "182": 1, "164": 1, "116": 1, "39": 1, "83": 1, "91": 1}	'activ':47 'arm':53,78 'back':25,41 'bandha':63 'direct':61 'earth':17,30,51 'engag':64 'extend':24,56,81 'firm':73 'floor':91 'forward':95 'gaze':93 'head':32 'heel':44 'hip':66 'iii':2A,4C 'leg':10,21,39,57,83 'lengthen':58 'one':9 'oppos':60 'parallel':27,88 'pelvi':76 'perpendicular':14 'posit':8,86 'press':40,72 'rais':23,82 'relat':87 'root':12,48 'squar':68 'stand':7,38 'tailbon':71 'thighbon':35 'torso':79 'toward':42 'virabhadrasana':3C 'warrior':1A
100	Standing Head to Knee (Preparation)	\N	\N	From a standing position the weight is balanced on one leg while the other leg is bent at the knee and pulled in close to the torso.  The palms meet under the sole of the foot and the fingers are interlaced under the foot (including the thumb) in preparation for Standing Head to Knee (Daṇḍayamana Jānushīrāsana) pose.  The spine is straight and the gaze is forward.	Intermediate	\N	Calms the brain and helps relieve mild depression.  Stretches the spine, shoulders, hamstrings and groins  Stimulates the liver and kidneys.  Improves digestion.  Helps relieve the symptoms of menopause.  Relieves anxiety, fatigue, headache and menstrual discomfort.  Therapeutic for high blood pressure, insomnia and sinusitis.	static/img/standing_head_to_knee_preparation_R.png	t	Standing Hand to Toe,Standing Head to Knee,Mountain	Standing Knee to Chest,Mountain	{"92": 1, "99": 1, "130": 1}	'balanc':13 'bent':22 'close':29 'daṇḍayamana':60 'finger':44 'foot':41,49 'forward':71 'gaze':69 'head':2A,57 'includ':50 'interlac':46 'jānushīrāsana':61 'knee':4A,25,59 'leg':16,20 'meet':35 'one':15 'palm':34 'pose':62 'posit':9 'prepar':5A,54 'pull':27 'sole':38 'spine':64 'stand':1A,8,56 'straight':66 'thumb':52 'torso':32 'weight':11
192	Wild Thing	Camatkārāsana	Camatkarasana	From Downward-Facing Dog (Adho Mukha Śvānāsana) pose, elevate one leg toward the sky and stack the corresponding hip over the other hip.  Bring the upper heel as close to the buttocks as possible.  The hips remain stacked; then bring the shoulders forward slowly over the hands.  Replace the corresponding hand to the upraised leg with the other hand and flip yourself over and extend the top hand forward.  The bottom foot is now facing toward the front of the mat and you remain on the ball of the top foot and the corresponding knee is bent.  Continue to lift hips up towards the sky and continue reaching the free hand towards the front of the room and slightly downwards.  Allow the head to curl back.	Intermediate	\N	Stretches the chest, shoulders, back, and throat.  Strengthens and opens the hips, hip flexors, and thighs.	static/img/wild_thing_L.png	t	One Legged Downward-Facing Dog	Downward-Facing Dog with Stacked Hips	{"70": 1, "64": 1, "68": 1}	'adho':9 'allow':125 'back':130 'ball':91 'bent':101 'bottom':75 'bring':28,44 'buttock':36 'camatkarasana':3C 'close':33 'continu':102,111 'correspond':22,54,98 'curl':129 'dog':8 'downward':6,124 'downward-fac':5 'elev':13 'extend':69 'face':7,79 'flip':65 'foot':76,95 'forward':47,73 'free':114 'front':82,118 'hand':51,55,63,72,115 'head':127 'heel':31 'hip':23,27,40,105 'knee':99 'leg':15,59 'lift':104 'mat':85 'mukha':10 'one':14 'pose':12 'possibl':38 'reach':112 'remain':41,88 'replac':52 'room':121 'shoulder':46 'sky':18,109 'slight':123 'slowli':48 'stack':20,42 'thing':2A 'top':71,94 'toward':16,80,107,116 'upper':30 'uprais':58 'wild':1A 'śvānāsana':11
139	Extended Side Plank	Utthita Vasiṣṭhāsana	Utthita Vasisthasana	From an arm balance position the weight of the body is supported on one side and distributed equally between the bottom arm and foot while the other (top) arm lifts with fingers spread wide and the other (top) foot stacks on top.  The top foot is raised up toward the sky and the top hand reaches over to grasp the toes.  The grounded (bottom) foot is flat and gripping the earth from the outside edge of the foot.  If flexibility of the foot is limited then instead of gripping the earth with a flat foot, the weight of the body is balanced on the side edge of the foot that is flexed instead of flat.  The arm supporting the weight of the body and the grounded foot actively press into the floor as the shoulder blades firm against the back and then widen away from the spine drawing toward the tailbone.  Bandhas are engaged to maintain balance and stability.  The crown of the head reaches away from the neck and the gaze is up towards the hand.	Expert	\N	Strengthens the arms, belly and legs.  Stretches and strengthens the wrists.  Stretches the backs of the legs.  Improves sense of balance and focus.	static/img/plank_side_extended_L.png	t	Side Plank	Side Plank	{"138": 1, "136": 1}	'activ':133 'arm':8,27,34,122 'away':149,171 'back':145 'balanc':9,107,162 'bandha':157 'blade':141 'bodi':15,105,128 'bottom':26,69 'crown':166 'distribut':22 'draw':153 'earth':76,96 'edg':80,111 'engag':159 'equal':23 'extend':1A 'finger':37 'firm':142 'flat':72,99,120 'flex':117 'flexibl':85 'floor':137 'foot':29,44,50,70,83,88,100,114,132 'gaze':177 'grasp':64 'grip':74,94 'ground':68,131 'hand':60,182 'head':169 'instead':92,118 'lift':35 'limit':90 'maintain':161 'neck':174 'one':19 'outsid':79 'plank':3A 'posit':10 'press':134 'rais':52 'reach':61,170 'shoulder':140 'side':2A,20,110 'sky':56 'spine':152 'spread':38 'stabil':164 'stack':45 'support':17,123 'tailbon':156 'toe':66 'top':33,43,47,49,59 'toward':54,154,180 'utthita':4C 'vasisthasana':5C 'weight':12,102,125 'wide':39 'widen':148
74	Eight Angle	Aṣṭāvakrāsana	Astavakrasana	Begin in Easy (Sukhāsana) pose, lift one knee up and make a shelf with the respective arm.  Slip the shoulder underneath this knee until the knee rests high up on the back of the shoulder.  Bend both elbows to a 90-degree angle and lean forward.  Bring the other foot over to meet the first and hook the feet.   Lean slightly towards the opposite side to place more weight on the corresponding side and begin to lift both feet off the ground.  Extend both legs simultaneously leaning your torso forward and lowering it until it is parallel to the mat.  Squeeze your upper arm between your thighs.  Use that pressure to help twist your torso to the opposite side.  Keep your elbows in close to the torso.  Gaze is towards the ground.	Expert	\N	Strengthens arms, legs, core and wrists.  Improves balance.	static/img/eight_angle_L.png	t	Flying Man	Flying Man	{"79": 1, "136": 1}	'90':44 'angl':2A,46 'arm':20,107 'astavakrasana':3C 'back':35 'begin':4,78 'bend':39 'bring':50 'close':127 'correspond':75 'degre':45 'easi':6 'eight':1A 'elbow':41,125 'extend':86 'feet':62,82 'first':58 'foot':53 'forward':49,93 'gaze':131 'ground':85,135 'help':115 'high':31 'hook':60 'keep':123 'knee':11,26,29 'lean':48,63,90 'leg':88 'lift':9,80 'lower':95 'make':14 'mat':103 'meet':56 'one':10 'opposit':67,121 'parallel':100 'place':70 'pose':8 'pressur':113 'respect':19 'rest':30 'shelf':16 'shoulder':23,38 'side':68,76,122 'simultan':89 'slight':64 'slip':21 'squeez':104 'sukhāsana':7 'thigh':110 'torso':92,118,130 'toward':65,133 'twist':116 'underneath':24 'upper':106 'use':111 'weight':72
97	Handstand with Splits	\N	\N	From an inverted position, balancing on the hands, one leg is extended forward and the other leg is extended back with equal and opposite force to maintain balance.  Depending on flexibility the legs are either extended straight or the knees are bent.  Arms are straight, the eye of the elbow is to the front of the room, Bandhas are engaged and the hands are pressed firmly down into the earth.  In this pose the arms are the fulcrum point that regulate the weight of the legs like a teeter-totter.  Keep the balance of the two legs equal in order to avoid toppling over.  The gaze is down and forward.	Expert	\N	Strengthens the shoulders, arms and wrists.  Stretches the belly.  Improves sense of balance.  Calms the brain and helps relieve stress and mild depression.	static/img/handstand_splits.png	t	Handstand	Handstand	{"96": 1, "64": 1, "152": 1, "171": 1}	'arm':46,78 'avoid':106 'back':23 'balanc':8,31,97 'bandha':61 'bent':45 'depend':32 'earth':73 'either':38 'elbow':53 'engag':63 'equal':25,102 'extend':15,22,39 'eye':50 'firm':69 'flexibl':34 'forc':28 'forward':16,114 'front':57 'fulcrum':81 'gaze':110 'hand':11,66 'handstand':1A 'invert':6 'keep':95 'knee':43 'leg':13,20,36,89,101 'like':90 'maintain':30 'one':12 'opposit':27 'order':104 'point':82 'pose':76 'posit':7 'press':68 'regul':84 'room':60 'split':3A 'straight':40,48 'teeter':93 'teeter-tott':92 'toppl':107 'totter':94 'two':100 'weight':86
115	Half Locust	Ardha Śalabhāsana	Ardha Salabhasana	Begin in a prone position, lying on the stomach with the arms along the sides of torso, the palms are up, the forehead is resting on the earth.  Turn the big toes towards each other to rotate the thighs inward and to firm the buttocks so that the coccyx (tailbone) presses towards the pubis.  Then lift the head, upper torso, arms, and legs away from the earth while resting the weight of the body on the lower ribs, belly, and front pelvis.  Firm the buttocks and reach strongly through the legs, first through the heels to lengthen the back legs, then through the bases of the big toes.  Keep the big toes turned toward each other.  The arms are raised parallel to the floor.  The fingers actively stretch and extend forward as the shoulders pull away from the ears.  The scapulae are pressed back and down firmly into the back.  The gaze is forward or slightly upward.  Be careful not to extend the chin forward and crunch the back of the neck.  Keep the base of the skull lifted and the back of the neck long.	Beginner	\N	Strengthens the muscles of the spine, the buttocks, and the backs of the arms and the legs.  Stretches the shoulders, the chest, the belly and the thighs.  Improves posture.  Stimulates abdominal organs.  Helps relieve stress.	static/img/locust_half_R.png	t	Front Corpse	Front Corpse	{"33": 1, "114": 1, "160": 1, "31": 1}	'activ':131 'along':17 'ardha':3C 'arm':16,65,122 'away':68,140 'back':103,148,154,173,186 'base':108,179 'begin':5 'belli':83 'big':35,111,115 'bodi':78 'buttock':49,89 'care':163 'chin':168 'coccyx':53 'crunch':171 'ear':143 'earth':32,71 'extend':134,166 'finger':130 'firm':47,87,151 'first':96 'floor':128 'forehead':27 'forward':135,158,169 'front':85 'gaze':156 'half':1A 'head':62 'heel':99 'inward':44 'keep':113,177 'leg':67,95,104 'lengthen':101 'lie':10 'lift':60,183 'locust':2A 'long':190 'lower':81 'neck':176,189 'palm':23 'parallel':125 'pelvi':86 'posit':9 'press':55,147 'prone':8 'pubi':58 'pull':139 'rais':124 'reach':91 'rest':29,73 'rib':82 'rotat':41 'salabhasana':4C 'scapula':145 'shoulder':138 'side':19 'skull':182 'slight':160 'stomach':13 'stretch':132 'strong':92 'tailbon':54 'thigh':43 'toe':36,112,116 'torso':21,64 'toward':37,56,118 'turn':33,117 'upper':63 'upward':161 'weight':75
120	Lunge	\N	\N	The weight of the body is supported on the front foot and the back toes.  The front knee is bent directly above the ankle in a 90-degree angle to the ankle.  The back heel is pressed to the back.  The inner thighs scissor towards each other and the hips are squared.  The ribcage is lifted and the heart is open.  The fingertips straddle the front leg and rest softly on the earth for balance.  You may use a block if necessary to keep the proper alignment.  The gaze is down and slightly forward.	Beginner	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.	static/img/lunge_R.png	t	Crescent Lunge,One Legged Downward-Facing Dog,Standing Forward Bend,Lunge with Arm Extended Forward,Lunge on the Knee,Pyramid,Standing Splits,Reverse Warrior,Warrior I	Crescent Lunge,Crescent Lunge Twist,Downward-Facing Dog with Bent Knees,Downward-Facing Dog with Knee to Forehead,One Legged Downward-Facing Dog,Standing Forward Bend,Halfway Lift,Lunge with Arm Extended Forward,Lunge with Arm Extended Up,Lunge on the Knee,Pyramid,Reverse Warrior,Warrior II	{"37": 1, "70": 1, "83": 1, "121": 1, "124": 1, "145": 1, "164": 1, "180": 1, "182": 1, "136": 1, "137": 1, "185": 1, "187": 1, "127": 1, "88": 1, "122": 1}	'90':28 'align':88 'angl':30 'ankl':25,33 'back':15,35,41 'balanc':76 'bent':21 'block':81 'bodi':6 'degre':29 'direct':22 'earth':74 'fingertip':64 'foot':12 'forward':95 'front':11,18,67 'gaze':90 'heart':60 'heel':36 'hip':51 'inner':43 'keep':85 'knee':19 'leg':68 'lift':57 'lung':1A 'may':78 'necessari':83 'open':62 'press':38 'proper':87 'rest':70 'ribcag':55 'scissor':45 'slight':94 'soft':71 'squar':53 'straddl':65 'support':8 'thigh':44 'toe':16 'toward':46 'use':79 'weight':3
123	Lunge with Hands on the Inside of the Leg	\N	\N	The front foot of one leg is rooted onto the earth with the knee directly above and tracking the ankle in a 90 degree angle.  The back leg is straight, no bend in the knee, and the weight is distributed backwards onto the toes as the back heel pushes back and down towards the earth.  The inner thighs scissor towards each other and the pelvis is tucked under with the ribcage lifted and the chin slightly tucked.  Both arms are straight (no bend in the elbows) on the inside of the front knee.  The palms are pressed into the earth with the fingers spread wide and the knuckles flat.  The gaze is forward and down following the natural extension of the neck.	Beginner	\N	Creates flexibility and strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, belly, groins (psoas) and the muscles of the back.  Strengthens and stretches the inner thighs, calves and ankles.	static/img/lunge_hands_on_mat_R.png	t	One Legged Downward-Facing Dog,Flying Man,Pyramid with Hands on the Inside of the Leg	One Legged Downward-Facing Dog,Pyramid with Hands on the Inside of the Leg,Bound Side Angle,Extended Side Angle	{"70": 1, "79": 1, "146": 1, "136": 1, "137": 1, "86": 1, "120": 1, "127": 1}	'90':32 'angl':34 'ankl':29 'arm':88 'back':36,56,59 'backward':50 'bend':41,92 'chin':84 'degre':33 'direct':24 'distribut':49 'earth':20,64,109 'elbow':95 'extens':128 'finger':112 'flat':118 'follow':125 'foot':12 'forward':122 'front':11,101 'gaze':120 'hand':3A 'heel':57 'inner':66 'insid':6A,98 'knee':23,44,102 'knuckl':117 'leg':9A,15,37 'lift':81 'lung':1A 'natur':127 'neck':131 'one':14 'onto':18,51 'palm':104 'pelvi':74 'press':106 'push':58 'ribcag':80 'root':17 'scissor':68 'slight':85 'spread':113 'straight':39,90 'thigh':67 'toe':53 'toward':62,69 'track':27 'tuck':76,86 'weight':47 'wide':114
146	Pyramid with Hands on the Inside of the Leg	\N	\N	From a standing position the front and back legs extend away from each other and the inner thighs scissor towards each other.  The spine is long and extended as the upper torso folds over the front leg and the palms reach for the earth on the inside of the leg.  The pelvis is tucked under, the ribcage is lifted and the chin is slightly tucked.  The neck is a natural is extension of the spine and the gaze is down.	Intermediate	\N	Calms the brain.  Stretches the spine, hips, and hamstrings.  Strengthens the legs.  Stimulates the abdominal organs.  Improves posture and sense of balance.  Improves digestion.	static/img/lunge_hands_on_mat_back_R.png	t	Lunge with Hands on the Inside of the Leg	Lunge with Hands on the Inside of the Leg	{"123": 1, "145": 1, "176": 1, "120": 1}	'away':20 'back':17 'chin':71 'earth':53 'extend':19,37 'extens':81 'fold':42 'front':15,45 'gaze':87 'hand':3A 'inner':26 'insid':6A,56 'leg':9A,18,46,59 'lift':68 'long':35 'natur':79 'neck':76 'palm':49 'pelvi':61 'posit':13 'pyramid':1A 'reach':50 'ribcag':66 'scissor':28 'slight':73 'spine':33,84 'stand':12 'thigh':27 'torso':41 'toward':29 'tuck':63,74 'upper':40
44	Reverse Crescent Lunge Twist	\N	\N	The front foot of one leg is rooted on the earth with the knee directly above and tracking the ankle in a 90 degree angle.  The back leg is straight, no bend in the knee, and the weight is distributed backwards onto the toes as the back heel pushes back and down towards the earth.  The inner thighs scissor towards each other and the pelvis is tucked under with the ribcage lifted and the chin slightly tucked.  The spine is long and extended.  The heart is open.  The arm corresponding to the front leg reaches back and down to touch the back thigh.  The other arm extends upwards towards the sky and slightly towards the back.	Intermediate	\N	Creates flexible strength.  Promotes stability in the front and back of the torso.  Tones the lower body.  Stretches the chest, lungs, shoulders, arms, neck, belly, groins (psoas) and the muscles of the back.  Strengthens and stretches the thighs, calves and ankles.	static/img/lunge_crescent_twist_reverse_R.png	t	Crescent Lunge Twist	Crescent Lunge Twist	{"43": 1, "37": 1, "38": 1, "120": 1, "180": 1}	'90':27 'angl':29 'ankl':24 'arm':93,110 'back':31,51,54,100,106,120 'backward':45 'bend':36 'chin':79 'correspond':94 'crescent':2A 'degre':28 'direct':19 'distribut':44 'earth':15,59 'extend':87,111 'foot':7 'front':6,97 'heart':89 'heel':52 'inner':61 'knee':18,39 'leg':10,32,98 'lift':76 'long':85 'lung':3A 'one':9 'onto':46 'open':91 'pelvi':69 'push':53 'reach':99 'revers':1A 'ribcag':75 'root':12 'scissor':63 'sky':115 'slight':80,117 'spine':83 'straight':34 'thigh':62,107 'toe':48 'touch':104 'toward':57,64,113,118 'track':22 'tuck':71,81 'twist':4A 'upward':112 'weight':42
71	Revolved Downward-Facing Dog	Parivṛtta Adho Mukha Śvānāsana	Parivrtta Adho Mukha Svanasana	From Downward-Facing Dog (Adho Mukha Śvānāsana), the legs are straight with the sits bones tilted up and reaching for the sky.  The feet are flat with the heels firmly rooted.  One palm is flat with the knuckles evenly pressed into the earth.  The other hand reaches under the body and grasps the opposite ankle.  The spine is long and the heart is open toward the sky.  The neck is loose and the crown of the head is relaxed toward the earth.  The gaze is toward the center.	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Energizes the body.  Stretches the shoulders, neck, hamstrings, calves, arches, and hands.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Relieves menstrual discomfort when done with the head supported.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica, and sinusitis.	static/img/downward_dog_hand_to_ankle_R.png	t	Downward-Facing Dog	Downward-Facing Dog	{"64": 1}	'adho':7C,15 'ankl':65 'bodi':60 'bone':25 'center':98 'crown':84 'dog':5A,14 'downward':3A,12 'downward-fac':2A,11 'earth':53,92 'even':49 'face':4A,13 'feet':34 'firm':40 'flat':36,45 'gaze':94 'grasp':62 'hand':56 'head':87 'heart':72 'heel':39 'knuckl':48 'leg':19 'long':69 'loos':81 'mukha':8C,16 'neck':79 'one':42 'open':74 'opposit':64 'palm':43 'parivrtta':6C 'press':50 'reach':29,57 'relax':89 'revolv':1A 'root':41 'sit':24 'sky':32,77 'spine':67 'straight':21 'svanasana':9C 'tilt':26 'toward':75,90,96 'śvānāsana':17
138	Side Plank	Vasiṣṭhāsana	Vasisthasana	From an arm balance position the weight of the body is supported on one side and distributed equally between the bottom arm and foot while the other (top) arm lifts with fingers spread wide and the other (top) foot stacks on top.  The grounded (bottom) foot is flat and gripping the earth from the outside edge of the foot.  If flexibility of the foot is limited then instead of gripping the earth with a flat foot, the weight of the body is balanced on the side edge of the foot that is flexed instead of flat.  The arm supporting the weight of the body and the grounded foot actively press into the floor as the shoulder blades firm against the back and then widen away from the spine drawing toward the tailbone.  Bandhas are engaged to maintain balance and stability.  The crown of the head reaches away from the neck and the gaze is up towards the hand.	Intermediate	\N	Calms the brain and helps relieve stress and mild depression.  Stretches the shoulders, hamstrings, calves, and arches.  Strengthens the arms and legs.  Helps relieve the symptoms of menopause.  Helps prevent osteoporosis.  Improves digestion.  Relieves headache, insomnia, back pain, and fatigue.  Therapeutic for high blood pressure, asthma, flat feet, sciatica.	static/img/plank_side_L.png	t	Plank,Extended Side Plank	Plank,Extended Side Plank,Side Plank on the Knee	{"136": 1, "139": 1.5, "64": 1, "142": 1}	'activ':112 'arm':6,25,32,101 'away':128,150 'back':124 'balanc':7,86,141 'bandha':136 'blade':120 'bodi':13,84,107 'bottom':24,48 'crown':145 'distribut':20 'draw':132 'earth':55,75 'edg':59,90 'engag':138 'equal':21 'finger':35 'firm':121 'flat':51,78,99 'flex':96 'flexibl':64 'floor':116 'foot':27,42,49,62,67,79,93,111 'gaze':156 'grip':53,73 'ground':47,110 'hand':161 'head':148 'instead':71,97 'lift':33 'limit':69 'maintain':140 'neck':153 'one':17 'outsid':58 'plank':2A 'posit':8 'press':113 'reach':149 'shoulder':119 'side':1A,18,89 'spine':131 'spread':36 'stabil':143 'stack':43 'support':15,102 'tailbon':135 'top':31,41,45 'toward':133,159 'vasisthasana':3C 'weight':10,81,104 'wide':37 'widen':127
80	Revolved Flying Man	Parivṛtta Eka Pāda Kouṇḍinyāsana	Parivrtta Eka Pada Koundinyasana	Starting from Downward-Facing Dog (Adho Mukha Śvānāsana) pose, bend both elbows to a 90-degree angle then cross one leg over the opposite elbow and extend the leg.  The other leg is extended back either balanced on the toes or suspended in flight with active toes.  The body is parallel to the earth.  The gaze is to the front.	Expert	\N	Strengthens arms, legs, core and wrists.  Improves balance.	static/img/flying_man_revolved_L.png	t	One Legged Downward-Facing Dog	One Legged Downward-Facing Dog	{"70": 1, "136": 1, "171": 1, "57": 1, "58": 1}	'90':23 'activ':54 'adho':14 'angl':25 'back':43 'balanc':45 'bend':18 'bodi':57 'cross':27 'degre':24 'dog':13 'downward':11 'downward-fac':10 'earth':62 'either':44 'eka':5C 'elbow':20,33 'extend':35,42 'face':12 'fli':2A 'flight':52 'front':68 'gaze':64 'koundinyasana':7C 'leg':29,37,40 'man':3A 'mukha':15 'one':28 'opposit':32 'pada':6C 'parallel':59 'parivrtta':4C 'pose':17 'revolv':1A 'start':8 'suspend':50 'toe':48,55 'śvānāsana':16
\.


--
-- Data for Name: poseworkouts; Type: TABLE DATA; Schema: public; Owner: vagrant
--

COPY public.poseworkouts (posework_id, pose_id, workout_id) FROM stdin;
1	130	1
2	131	1
3	83	1
4	91	1
5	171	1
6	179	1
7	64	1
8	91	1
9	83	1
10	131	1
11	130	1
12	130	2
13	22	2
14	83	2
15	91	2
16	171	2
17	179	2
18	64	2
19	182	2
20	171	2
21	179	2
22	64	2
23	182	2
24	171	2
25	179	2
26	64	2
27	91	2
28	83	2
29	22	2
30	130	2
31	130	3
32	131	3
33	83	3
34	91	3
35	37	3
36	64	3
37	136	3
38	171	3
39	179	3
40	64	3
41	37	3
42	91	3
43	83	3
44	131	3
45	130	3
46	64	4
47	37	4
48	182	4
49	187	4
50	180	4
51	156	4
52	177	4
53	176	4
54	90	4
55	64	4
56	22	5
57	72	5
58	175	5
59	116	5
60	189	5
61	164	5
62	88	5
63	89	5
64	90	5
65	83	5
66	130	6
67	182	6
68	185	6
69	187	6
70	180	6
71	189	6
72	37	7
73	107	7
74	111	7
75	89	7
76	116	7
77	19	7
78	10	7
79	19	7
80	20	8
81	34	8
82	20	8
83	34	8
84	2	8
85	70	8
86	136	8
87	138	8
88	64	8
89	37	8
90	88	8
91	22	8
92	72	8
93	6	8
94	94	9
95	83	9
96	176	9
97	163	9
98	135	9
99	8	9
100	111	9
101	72	9
102	17	9
103	35	9
104	64	10
105	136	10
106	138	10
107	139	10
108	136	10
109	171	10
110	179	10
111	68	10
112	67	10
113	137	10
114	8	11
115	119	11
116	36	11
117	8	11
118	21	11
119	163	11
120	20	12
121	34	12
122	20	12
123	34	12
124	160	12
125	78	12
126	17	12
127	7	12
128	84	12
129	176	12
130	64	12
131	130	13
132	84	13
133	20	13
134	34	13
135	20	13
136	34	13
137	17	13
138	72	13
139	136	13
\.


--
-- Data for Name: workouts; Type: TABLE DATA; Schema: public; Owner: vagrant
--

COPY public.workouts (workout_id, duration, name, author, description) FROM stdin;
1	11	Sun Salutation A	\N	A basic yoga sequence to start your practice. Repeat 3-4 times to warm up.
2	19	Sun Salutation B	\N	A basic yoga sequence to start your practice. Repeat 3-4 times to warm up.
3	15	Sun Salutation A - variation	\N	A variation on the basic yoga sequence to start your practice. Repeat 3-4 times to warm up.
4	10	Classic Standing Poses	\N	A series of classic standing poses. Repeat 2-3 times
5	10	Core & Standing Poses	\N	A series of standing poses that focus on core.
6	6	Warrior Mode	\N	Practice all the warrior poses together
7	8	Stretch Your Quads	\N	Stretch your quads
8	14	Core Workout	\N	Work your core with this series of poses
9	10	Flexibility	\N	Improve your flexibility with these stretches
10	10	Triceps/Biceps	\N	Tone your arms with this sequence
11	6	Hip Openers	\N	Stretch your hips
12	11	Chest/Shoulder Openers	\N	Perfect for those who sit hunched over a desk all day
13	9	Improve Posture	\N	Improve your posture with this chest/shoulder sequence
\.


--
-- Name: categories_cat_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vagrant
--

SELECT pg_catalog.setval('public.categories_cat_id_seq', 28, true);


--
-- Name: posecategories_posecat_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vagrant
--

SELECT pg_catalog.setval('public.posecategories_posecat_id_seq', 698, true);


--
-- Name: poses_pose_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vagrant
--

SELECT pg_catalog.setval('public.poses_pose_id_seq', 194, true);


--
-- Name: poseworkouts_posework_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vagrant
--

SELECT pg_catalog.setval('public.poseworkouts_posework_id_seq', 139, true);


--
-- Name: workouts_workout_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vagrant
--

SELECT pg_catalog.setval('public.workouts_workout_id_seq', 13, true);


--
-- Name: categories categories_name_key; Type: CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_name_key UNIQUE (name);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (cat_id);


--
-- Name: posecategories posecategories_pkey; Type: CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.posecategories
    ADD CONSTRAINT posecategories_pkey PRIMARY KEY (posecat_id);


--
-- Name: poses poses_name_key; Type: CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.poses
    ADD CONSTRAINT poses_name_key UNIQUE (name);


--
-- Name: poses poses_pkey; Type: CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.poses
    ADD CONSTRAINT poses_pkey PRIMARY KEY (pose_id);


--
-- Name: poseworkouts poseworkouts_pkey; Type: CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.poseworkouts
    ADD CONSTRAINT poseworkouts_pkey PRIMARY KEY (posework_id);


--
-- Name: workouts workouts_pkey; Type: CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.workouts
    ADD CONSTRAINT workouts_pkey PRIMARY KEY (workout_id);


--
-- Name: ix_poses_search_vector; Type: INDEX; Schema: public; Owner: vagrant
--

CREATE INDEX ix_poses_search_vector ON public.poses USING gin (search_vector);


--
-- Name: poses poses_search_vector_trigger; Type: TRIGGER; Schema: public; Owner: vagrant
--

CREATE TRIGGER poses_search_vector_trigger BEFORE INSERT OR UPDATE ON public.poses FOR EACH ROW EXECUTE PROCEDURE public.poses_search_vector_update();


--
-- Name: posecategories posecategories_cat_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.posecategories
    ADD CONSTRAINT posecategories_cat_id_fkey FOREIGN KEY (cat_id) REFERENCES public.categories(cat_id);


--
-- Name: posecategories posecategories_pose_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.posecategories
    ADD CONSTRAINT posecategories_pose_id_fkey FOREIGN KEY (pose_id) REFERENCES public.poses(pose_id);


--
-- Name: poseworkouts poseworkouts_pose_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.poseworkouts
    ADD CONSTRAINT poseworkouts_pose_id_fkey FOREIGN KEY (pose_id) REFERENCES public.poses(pose_id);


--
-- Name: poseworkouts poseworkouts_workout_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vagrant
--

ALTER TABLE ONLY public.poseworkouts
    ADD CONSTRAINT poseworkouts_workout_id_fkey FOREIGN KEY (workout_id) REFERENCES public.workouts(workout_id);


--
-- PostgreSQL database dump complete
--


# Yoga Warrior ([Demo](https://yoga-app.herokuapp.com/))

## Background
Yoga Warrior will randomly create a yoga workout for you. Using Markov chains and a database of yoga poses, the app will generate a sequence of yoga poses that users can follow for your next workout. Users can adjust the difficulty level, choose a different emphasis, save their workouts, or choose from already created workouts. Users can also search and browse through the database of all yoga poses to find out more info about poses. With each saved workout, the app will improve its model to generate better workouts the next time.

The pose information and pictures were scraped from the site Pocket Yoga using Beautiful Soup.

Created as a final project for the Hackbright Academy Software Engineering program.

### Tech Stack
Python (Flask, SQLAlchemy), PostgreSQL Database, Javascript, Bootstrap


## Features

### Create a Workout
Get started by going to the homepage and selecting the duration, difficulty, emphasis (if any), 
and selecting whether you'd like a timed workout or to go at your own pace.

Click Start Workout. 
![homepage](/static/img/readme-imgs/homepage.png)
<img src="/static/img/readme-imgs/homepage.png" width="200">

#### Controls
If you chose a Timed workout, you'll see a play button. If you click it, it will start the workout
at the current pose displayed and automatically show the next pose in the workout after 20 seconds 
(Later verisions, I will update the timing to be adjustable depending on the pose). 

You can click pause to stop the workout. You can also just skip to the next pose yourself by clicking
the next button that is beside the play button.
![workout](/static/img/readme-imgs/workout-1.png)

The thumbnails below the pose picture show the upcoming poses in the workout. You can click the left
and right arrows to preview the entire workout. You can also skip ahead to those poses by clicking on the
thumbnails directly. 
![workout2](/static/img/readme-imgs/workout-2.png)

Clicking on the picture of the current pose on the workout will take to the details of that pose where 
you can read more about the pose itself. 

You can also save the workout if you enjoyed it and so you can repeat the workout later if you want. Clicking
the Save Workout button will open a modal where you fill out information before saving it. As of now, all 
saved workouts are public and viewable by everyone. (This will probably be changed if I add user accounts) 
![save-workout](/static/img/readme-imgs/save-workout.png)

Clicking the Exit Workout button will clear the workout and take you back to the homepage

### View Saved Workouts
You can view all saved workouts on this page. The site includes some popular yoga sequences such as 
Sun Salutations A & B. When you save a workout, it will appear on this page. Each saved workout shows a small
preview of the workout. If you click Do This Workout, it will load the workout and take you to the workout page,
where you can start the workout.
![saved-workouts](/static/img/readme-imgs/saved-workouts.png)

### Pose Dictionary
The site also includes a pose dictionary where you can search for a pose and find out more information about it.
![pose dictionary](/static/img/readme-imgs/pose-dictionary-1.png)

The search feature was implemented using PostgresQL's full text search. The results are sorted by relevance with 
poses whose titles match the keyword appearing first and poses whose description match the keywords appearing towards the end. 

The search also includes some faceted search which you can see on the left column of the search page. For the following
keyword "warrior", you can see that 6 of those results are Beginner poses, 5 of those results are Intermediate, etc. Clicking any of those difficulties and hitting search again will update the results to only show those poses that match
the keyword and difficulty. The same can be done for the Category filters. 
![pose dictionary2](/static/img/readme-imgs/pose-dictionary-2.png)


#### Pose Details 
The pose detail page shows you all information for that pose. Clicking on a category shows you a page of all poses under
that category.
![pose details](/static/img/readme-imgs/pose-details.png)


## How to Run Locally
After setting up and activating your own local virtual environment, run the requirements.txt file with
`pip install -r requirements.txt`

To populate the database, make sure to you have postgresQL on your local machine. 
Create a local db called yogaposes with
`createdb yogaposes`

Import the backup sql file to load all the tables with the command
`psql yogaposes < backup_12072018.sql`

Run it locally with
`python3 server.py`

Navigate to http://0.0.0.0:5000/ in your browser to view the site!

## How It Works
In case you're interested in how I set up the backend for this app and made the Markov
chain generator. 

Link to some info on [Markov chains](http://setosa.io/ev/markov-chains/) if you need some background 

### Setting up the Markov Chains
Conveniently enough, the data from Pocket Yoga already included some info that I could use for the Markov
chains. For some poses, the site listed next poses or poses that would make sense to follow after that pose. 

Using this information I constructed my Poses table to include a "next_poses" column for each pose. Utilizing
the fact that you can have JSON column types in a PostgresQL database (yay!), I made a dictionary of 
next poses for each pose that lists the pose id and the corresponding weight. 

For example, for the pose Warrior I, the "next_poses" column included Warrior II and Warrior III (to name a few).
So the data in the next_poses column would look like { '15': 1, '17': 1 }. Where the keys of the dictionary
are the pose ids and the values are the weights, which are used for the Markov chain generation.

Then, I created a method getNextPose for my Pose class (jumping into ORM land now) that can be used for each pose. 
This method takes a pose's next_poses attribute, selects a pose id from one of those based on the weights and returns that
pose. I used Python's built-in [random.choices](https://docs.python.org/3/library/random.html) function to select a next pose. The random.choices function lets you input
a list of weights as an option. Selections are made according to relative weights. So those with a higher weight are more likely to be chosen.  

So taking from my previous example of Warrior I with next poses of { Warrior II: 1, Warrior III: 1}. If I used the 
getNextPose method for Warrior I, the function would then return Warrior II or Warrior III with equal probability since
their weights are the same (the value 1).

Now I'm ready to start generating some workouts!

### Generating a Workout (aka making the Markov chains!)
Since the user can input the difficulty and an emphasis for the workout, I use the information to generate a 
database query to grab the right pool of poses to choose from. From there I randomly pick a start pose and keep
generating a next pose until I hit the limit (which is specified by the duration/# of total poses the user specified)


### Refining the Model
The workouts generated by the first version of this were very naive and not the most interesting of yoga sequences. There were 2 problems: 
1) there were not enough relationships set up between poses, so the workouts generated would often
cycle back and forth between a few poses (which is not very interesting!) 
2) the other was that if a user inputted a difficulty or emphasis, that ended up narrowing the pool of poses even more, e.g. if a user selected an Expert difficulty it would only take from expert level poses and not from any beginner or intermediate poses at all. Which doesn't make a lot of sense since an ideal expert level workout would include some beginner and intermediate poses with an emphasis on expert level poses. 

To solve the first problem, I used known yoga sequences (such as Sun Salutation A, Sun Salutation B, etc.) to refine and update the weights. Basically, I went through each of those known yoga sequences, took the current pose, found it in my database, checked the next pose in the sequence and checked to see if my current pose had this next pose listed in its attribute. If not, I added that next pose. If it was in there, I increased the weight for the pose. This improved the workouts generated by a little bit but more importantly in doing this, I set up the system so it could improve with time.
![saved workouts 2](/static/img/readme-imgs/saved-workouts-2.png)


When the user saves a workout, I assume that it means they like the workout enough that the sequence of poses are good and make sense. So we update the weights of the poses in the saved workout accordingly when the user saves the workout. This means that as more users save workouts the model will improve and sort of normalize the workouts it creates. 

Even with these adjustments, I still had to massage the data a bit more to establish relationships between poses and create relationships for poses that previously had no ties to other poses. Unfortunately, I couldn't really think of an automated way of doing it, so I had to spend a bit of time manually entering in all the relationships between poses. 

For the second problem, to expand the pool of poses to choose from when a user selects a difficulty and/or emphasis, I did it in steps. I first took all the poses that exactly meet the user's requirements, e.g. if it was intermediate level and the emphasis was on abs/core, I took all the poses that exactly met that criteria. This was ranked first. 

I then created a second set of alternate poses to choose from that met the criteria but were of lower difficulty. So for the above example, I took all the poses that were of beginner level and emphasis was on abs/core. This is ranked second. 

Finally I created a set of 30 basic poses that can be included in any level workout. These poses are just standard poses that are common in every yoga workout (such as downward dog, mountain, etc.) This is ranked last.

With this new expanded pool of poses to choose from, when a next pose is chosen I check to make sure that the pose is either in the 1st set, 2nd set or third set. 

All these changes combined seemed to improve the workouts generated. At this point, I was mostly looking for a variety of poses in the workout for a more interesting/varied workout and making sure that a workout didn't just cycle back and forth between a few poses. There's still lots to be done though!


## Future Things aka Stuff I want to Add
- More Testing! (I only have a few tests written so far)
- Mobile optimized layout
- Restart/looping through a workout
- User Accounts/Login (Google Login)
  - also have an Admin mode so that only certain people make changes
- Voice narration




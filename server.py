from jinja2 import StrictUndefined

from flask import Flask, render_template, redirect, request, flash, session, jsonify, json
from flask_debugtoolbar import DebugToolbarExtension
from sqlalchemy.orm.attributes import flag_modified

# from model import connect_to_db, db, Pose, Workout, PoseWorkout, PoseCategory, Category, generateWorkout
from model import * 

app = Flask(__name__)

# Required to use Flask sessions and the debug toolbar
app.secret_key = "ABC"
app.jinja_env.undefined = StrictUndefined


@app.route('/')
def homepage():
    """display homepage"""

    # all_poses = Pose.query.order_by('name').all()
    # all_categories = Category.query.order_by('name').all()
    return render_template("homepage.html")


@app.route('/search')
def searchPoses():
    """Search for poses by keyword (looks through name, alt names, sanskrit), category
    & difficulty
    
    Lists the poses that meet those search requirements 
    """

    # TODO: make keyword search not case sensitive
    # TODO: make keyword search through the alt names, sanskrit as well

    if request.args:
        keyword = '%' + request.args.get('keyword') + '%'

        difficulty = request.args.getlist('difficulty') # list of difficulty
        if not difficulty: # if the list is empty
            difficulty = ['Beginner', 'Intermediate', 'Expert']

        categories = request.args.getlist('categories') # list of categories
        if not categories:
            all_cat_ids = db.session.query(Category.cat_id).all() # returns a list of tuples of all the ids
            categories = [category[0] for category in all_cat_ids] # converts that to a list

        all_poses = db.session.query(Pose).join(PoseCategory).filter(Pose.name.like(keyword),
                                                                Pose.difficulty.in_(difficulty),
                                                                PoseCategory.cat_id.in_(categories)).all()
    else:
        all_poses = Pose.query.order_by('name').all()

    all_categories = Category.query.order_by('name').all()

    return render_template("search.html", all_poses=all_poses, categories=all_categories)


@app.route('/pose/<pose_id>')
def showPoseDetails(pose_id):
    """Show the pose details"""

    pose = Pose.query.get(pose_id)
    next_poses = None
    if pose.next_poses: # pose.next_poses = dictionary of next poses {pose_id: weight, pose_id: weight}
        next_poses = {} # want to compose a dictionary {pose_id: {name: "Down Dog", weight: 1} ... }
        for p in pose.next_poses:
            p_name = db.session.query(Pose.name).filter(Pose.pose_id == int(p)).first()[0]
            next_poses[p] = {"name": p_name, "weight": pose.next_poses[p]}

    prev_poses = None
    if pose.prev_pose_str:
        prev_poses = pose.prev_pose_str.split(',') # list of previous poses

    return render_template("pose-details.html", 
                            pose=pose,
                            next_poses=next_poses,
                            prev_poses=prev_poses)


@app.route('/workout.json')
def createWorkout():
    """Given a number of poses, return a list of poses with their id, img urls, and name"""
    num_poses = int(request.args.get('num_poses'))
    workout_list = generateWorkout(num_poses)

    workout_jsonlist = []

    # unpack the workout list to display on the page
    for i, pose in enumerate(workout_list):
        workout_jsonlist.append({'pose_id' : pose.pose_id, 'imgurl': pose.img_url, 'name': pose.name})
    
    session['workout'] = workout_jsonlist
    # do I want to create a workout automatically? and then save workout will just be saving
    #  it to be associated with a certain user?

    return jsonify({'workout_list': workout_jsonlist})


@app.route('/saveworkout', methods=['POST'])
def saveWorkout():
    """Takes the current workout that is in the Flask session and create a new Workout
    object and save it to the database
    """
    
    # TODO associate that workout with a user
    results = {'isInSession': False}

    if session.get('workout'):
        results['isInSession'] = True
        workout = Workout(duration=len(session['workout']))
        db.session.add(workout)
        db.session.commit()

        for pose in session['workout']:
            poseworkout = PoseWorkout(pose_id=pose['pose_id'], workout_id=workout.workout_id)
            db.session.add(poseworkout)
            db.session.commit()

    else: 
        print("no workout in session")

    return jsonify(results)


@app.route('/saveweights.json', methods=['POST'])
def saveWeights():
    """Takes in a pose (via pose id) and dictionary of next pose ids and weights
    Updates the database with the new pose weights"""

    data = request.get_json() # data = {'pose_id': 2, 'next_poses': {'12': 1, '13', 2} }

    if data:
        poseid = data['pose_id']
        next_poses = data['next_poses']
        pose = Pose.query.get(poseid)
        print("pose is ", pose)
        print("next_poses is", next_poses)
        pose.next_poses = next_poses
        db.session.commit()

    return jsonify(next_poses)


@app.route('/addnextpose', methods=['POST'])
def addNextPose():
    """Takes in a pose id and weight and adds that to the next pose attribute for the
    original pose
    """
    poseid = int(request.form.get('poseid'))
    next_poseid = request.form.get('nextposeid')
    weight = request.form.get('weight')

    if next_poseid and weight:
        pose = Pose.query.get(poseid)
        next_poses = pose.next_poses
        pose.next_poses[next_poseid] = int(weight)
        print(pose.next_poses)
        flag_modified(pose, 'next_poses') # let database know that this field has been modified
        db.session.commit()

    url = '/pose/' + str(poseid)
    return redirect(url)


@app.route('/removenextpose', methods=['POST'])
def removeNextPose():
    """Takes in a pose id, weight and removes that from the next pose attribute for the 
    original pose"""

    data = request.get_json() # data = {'pose_id': 2, 'nextposeid': 12, 'weight': 1}
    print(data)
    if data['nextposeid']:
        pose = Pose.query.get(data['pose_id'])
        next_poses = pose.next_poses
        del next_poses[data['nextposeid']]
        flag_modified(pose, 'next_poses')
        db.session.commit()

    url = '/pose/' + str(poseid)
    return redirect(url)

if __name__ == "__main__":
    # We have to set debug=True here, since it has to be True at the
    # point that we invoke the DebugToolbarExtension
    app.debug = True
    app.jinja_env.auto_reload = app.debug

    PRODUCTION_DB_URI = 'postgresql:///yogaposes'

    connect_to_db(app, PRODUCTION_DB_URI)

    # Use the DebugToolbar
    DebugToolbarExtension(app)

    app.run(host='0.0.0.0')
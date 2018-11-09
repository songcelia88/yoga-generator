from jinja2 import StrictUndefined

from flask import Flask, render_template, redirect, request, flash, session
from flask_debugtoolbar import DebugToolbarExtension

from model import connect_to_db, db, Pose, Sequence, PoseSeq, PoseCategory, Category

app = Flask(__name__)

# Required to use Flask sessions and the debug toolbar
app.secret_key = "ABC"
app.jinja_env.undefined = StrictUndefined


@app.route('/')
def homepage():
    """display homepage which currently lists all the poses"""

    all_poses = Pose.query.order_by('name').all()
    all_categories = Category.query.order_by('name').all()
    return render_template("homepage.html", all_poses=all_poses, categories=all_categories)

@app.route('/search')
def searchPoses():
    """Search for poses by keyword (looks through name, alt names, sanskrit), category
    & difficulty
    
    Lists the poses that meet those search requirements 
    """

    # TODO: make keyword search not case sensitive
    # TODO: make keyword search through the alt names, sanskrit as well
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

    all_categories = Category.query.order_by('name').all()

    return render_template("homepage.html", all_poses=all_poses, categories=all_categories)


@app.route('/pose/<pose_id>')
def showPoseDetails(pose_id):
    """Show the pose details"""

    pose = Pose.query.get(pose_id)
    next_poses = None
    if pose.next_pose_str:
        next_poses = pose.next_pose_str.split(',') # list of next poses

    prev_poses = None
    if pose.prev_pose_str:
        prev_poses = pose.prev_pose_str.split(',') # list of previous poses

    return render_template("pose-details.html", 
                            pose=pose,
                            next_poses=next_poses,
                            prev_poses=prev_poses)


if __name__ == "__main__":
    # We have to set debug=True here, since it has to be True at the
    # point that we invoke the DebugToolbarExtension
    app.debug = True
    app.jinja_env.auto_reload = app.debug

    connect_to_db(app)

    # Use the DebugToolbar
    DebugToolbarExtension(app)

    app.run(host='0.0.0.0')
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy.dialects.postgresql import JSON
import random

# This is the connection to the PostgreSQL database; we're getting this through
# the Flask-SQLAlchemy helper library. On this, we can find the `session`
# object, where we do most of our interactions (like committing, etc.)

# This assumes the database has been seeded with the seed.py file

db = SQLAlchemy()

##############################################################################
# Model classes

class Pose(db.Model):
    __tablename__ = "poses"

    pose_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    name = db.Column(db.String(100), nullable=False, unique=True) # required and unique
    sanskrit = db.Column(db.String(100), nullable=True) # sanskrit name
    description = db.Column(db.String(2000))
    difficulty = db.Column(db.String(20), nullable=False)
    altNames = db.Column(db.String(100), nullable=True)
    benefit = db.Column(db.String(1000), nullable=True)
    img_url = db.Column(db.String(200), nullable=False)
    next_pose_str = db.Column(db.String(500), nullable=True) # next poses stored as a string for now
    prev_pose_str = db.Column(db.String(500), nullable=True) # previous poses stored as a string for now
    next_poses = db.Column(JSON, nullable=True) # next poses as a JSON {pose_id: weight, pose_id: weight, ....}


    pose_workout = db.relationship('PoseWorkout')
    pose_categories = db.relationship('PoseCategory')

    def getNextPose(self):
        """
        Returns a Pose object that would follow based on
        choosing a pose from the original Pose object's next_poses attribute
        
        e.g. 
        Usage: warrior2.getNextPose() 
        Output: <Pose name="Warrior I">

        """
        if self.next_poses: # if the next_poses attribute exists for that pose
            pose_ids = []
            pose_weights = []
            for pose_id, weight in self.next_poses.items(): # pose.next_poses = {id: weight, id: weight ...}
                pose_ids.append(int(pose_id))
                pose_weights.append(weight)

        else: # if no next poses exist then choose from some basic ones like Mountain, Down Dog
            pose_ids =[64,130,32]
            pose_weights = [2,2,1]

        next_pose_id = random.choices(pose_ids, pose_weights)[0] # random.choices returns a list

        return Pose.query.get(next_pose_id)

    def __repr__(self):
        """Print out the Pose object nicely"""
        return "<Pose pose_id={}, name={}>".format(self.pose_id, self.name)


class Workout(db.Model):
    __tablename__ = "workouts"

    workout_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    duration = db.Column(db.Integer, nullable=False) # in minutes

    pose_workouts = db.relationship('PoseWorkout')

    def __repr__(self):
        """Print out the Workout Object nicely"""
        return "<Workout workout_id={}, duration={}>".format(self.workout_id, self.duration)


class PoseWorkout(db.Model):
    __tablename__ = "poseworkouts"

    posework_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    pose_id =  db.Column(db.Integer, db.ForeignKey('poses.pose_id'), nullable=False)
    workout_id = db.Column(db.Integer, db.ForeignKey('workouts.workout_id'), nullable=False)

    workout = db.relationship('Workout')
    pose = db.relationship('Pose')

    def __repr__(self):
        """Print out the Pose-Workout object nicely"""
        return "<PoseWorkout pose name = {}, workout_id = {}>".format(self.pose.name, self.workout_id)


class PoseCategory(db.Model):
    __tablename__ = 'posecategories'

    posecat_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    pose_id = db.Column(db.Integer, db.ForeignKey('poses.pose_id'), nullable=False)
    cat_id = db.Column(db.Integer, db.ForeignKey('categories.cat_id'), nullable=False)

    pose = db.relationship('Pose')
    category = db.relationship('Category')

    def __repr__(self):
        return "<PoseCategory id={}, pose={}, category={}>".format(self.posecat_id, self.pose.name, self.category.name)


class Category(db.Model):
    __tablename__ = "categories"

    cat_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    name = db.Column(db.String(100), nullable=False, unique=True) # required and unique

    pose_categories = db.relationship('PoseCategory')

    def __repr__(self):
        """Print out the category object nicely"""
        return "<Category cat_id ={}, name={}>".format(self.cat_id, self.name)

##############################################################################
# Helper functions
# warrior2 = Pose.query.get(187)
def generateWorkout(num_poses):
    """Generate a list of Poses, take an input the number of poses and returns a 
    list of Poses, save that result as a Workout object
    """

    # TO DO: want to incorporate choosing from different pose sets (adjust difficulty, pose types)
    
    # start with a pose
    start_pose = random.choice(Pose.query.all())
    # start_pose = Pose.query.get(130) # Mountain Pose Id is 130
    workout_list = [start_pose]

    while len(workout_list) <= num_poses:
        next_pose = workout_list[-1].getNextPose()
        workout_list.append(next_pose)

    return workout_list


# def saveWorkout(poses_list): (make this a route to save the workout?)
    # create workout object and commit it
    # for each pose in the workout list, create PoseWorkout object with the id of that 
    #     pose and id of the workout
    # return the workout object


def connect_to_db(app):
    """Connect the database to our Flask app."""

    # Configure to use our PstgreSQL database
    app.config['SQLALCHEMY_DATABASE_URI'] = 'postgresql:///yogaposes'
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    db.app = app
    db.init_app(app)

if __name__ == "__main__":
    # As a convenience, if we run this module interactively, it will leave
    # you in a state of being able to work with the database directly.

    from server import app
    connect_to_db(app)
    # db.create_all()
    print("Connected to DB.")


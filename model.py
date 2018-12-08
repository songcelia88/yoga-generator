from flask_sqlalchemy import SQLAlchemy, BaseQuery
from sqlalchemy_searchable import SearchQueryMixin
from sqlalchemy_utils.types import TSVectorType
from sqlalchemy_searchable import make_searchable, search
from sqlalchemy.dialects.postgresql import JSON, ARRAY
from sqlalchemy import func
import random
import copy


# This is the connection to the PostgreSQL database; we're getting this through
# the Flask-SQLAlchemy helper library. On this, we can find the `session`
# object, where we do most of our interactions (like committing, etc.)

# This assumes the database has been seeded with the seed.py file

db = SQLAlchemy()

make_searchable(db.metadata)

DIFFICULTIES = ['Beginner', 'Intermediate', 'Expert']
# DEFAULT_POSE_IDS = [64,130,32] # ids for Down Dog, Mountain, and Corpse

# ids for the 30ish basic poses that can be included in every workout (sorted by difficulty)
# source: https://greatist.com/move/common-yoga-poses
BEGINNER_POSE_IDS = [130, 22, 75, 64, 187, 176, 175, 17, 8, 32, 7, 143, 182, 81] 
INTERMEDIATE_POSE_IDS = [136, 171, 179, 88, 182, 189, 145, 60, 10, 19, 6, 138, 54, 178, 153]
ADVANCED_POSE_IDS = [96, 132, 190, 101, 154]

DEFAULT_POSE_IDS = [BEGINNER_POSE_IDS, INTERMEDIATE_POSE_IDS, ADVANCED_POSE_IDS] # a list of lists


##############################################################################
# Model classes
class PoseQuery(BaseQuery, SearchQueryMixin):
    pass

class Pose(db.Model):
    query_class = PoseQuery
    __tablename__ = "poses"

    pose_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    name = db.Column(db.Unicode(100), nullable=False, unique=True) # required and unique, SEARCHABLE
    sanskrit = db.Column(db.Unicode(100), nullable=True) # sanskrit name with accents (for displaying)
    sanskrit_unaccented = db.Column(db.Unicode(100), nullable=True) # sanskrti name w/o accents, SEARCHABLE
    description = db.Column(db.Unicode(2000)) # SEARCHABLE
    difficulty = db.Column(db.String(20), nullable=False)
    altnames = db.Column(db.Unicode(100), nullable=True) # SEARCHABLE
    benefit = db.Column(db.String(1000), nullable=True)
    img_url = db.Column(db.String(200), nullable=False)
    is_leftright = db.Column(db.Boolean, nullable=True) # boolean to indicate whether a pose has left/right version
    next_pose_str = db.Column(db.String(500), nullable=True) # next poses stored as a string for now
    prev_pose_str = db.Column(db.String(500), nullable=True) # previous poses stored as a string for now
    next_poses = db.Column(JSON, nullable=True) # next poses as a JSON {pose_id: weight, pose_id: weight, ....}

    search_vector = db.Column(TSVectorType('name','sanskrit_unaccented','altnames','description',
                                         catalog='pg_catalog.simple',
                                         weights={'name': 'A', 'altnames': 'B', 'sanskrit_unaccented': 'C', 'description':'D'}))
    pose_workout = db.relationship('PoseWorkout')
    pose_categories = db.relationship('PoseCategory')

    def getNextPose(self, next_poses=None):
        """
        Returns a Pose object that would follow based on
        choosing a pose from the original Pose object's next_poses attribute 
        OR it can take in a user specified next poses dictionary

        next_poses must be a dictionary = {id: weight, id: weight ...} 
        
        e.g. 
        Usage: warrior2.getNextPose() 
        Output: <Pose name="Warrior I">

        """

        if next_poses is None: # if no next poses are specified use the ones in the attribute for that pose
            next_poses = self.next_poses

        if next_poses: # if the next_poses exists for that pose (i.e. it's not an empty dictionary)
            pose_ids = []
            pose_weights = []
            for pose_id, weight in next_poses.items(): # next_poses = {id: weight, id: weight ...}
                pose_ids.append(int(pose_id))
                pose_weights.append(weight)

        else: # if no next poses exist then choose from some basic ones like Mountain, Down Dog
            pose_ids =[64,130,32] # ids for Down Dog, Mountain, and Corpse
            pose_weights = [2,2,1]

        next_pose_id = random.choices(pose_ids, pose_weights)[0] # random.choices returns a list

        return Pose.query.get(next_pose_id)

    def __repr__(self):
        """Print out the Pose object nicely"""
        return "<Pose pose_id={}, name={}>".format(self.pose_id, self.name)


class Workout(db.Model):
    __tablename__ = "workouts"

    workout_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    duration = db.Column(db.Integer, nullable=False) # in minutes/num of poses
    name = db.Column(db.String(200), nullable=True)
    author = db.Column(db.String(200), nullable=True)
    description = db.Column(db.String(1000), nullable=True)
    # difficulty = db.Column(db.String(50), nullable=True)

    pose_workouts = db.relationship('PoseWorkout')

    def __repr__(self):
        """Print out the Workout Object nicely"""
        return "<Workout workout_id={}, duration={}, name={}>".format(self.workout_id, self.duration, self.name)


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

def generateWorkout(num_poses, difficulty=DIFFICULTIES, categories=None):
    """Generate a list of Poses, take an input the number of poses and returns a 
    list of Pose objects

    num_poses is an integer
    difficulty is a list of difficulties ['Beginner'] or ['Beginner', 'Intermediate']
    NOTE: right now I'm only inputting a list of one difficulty level!
    categories is a list of category ids [2, 4, 6]

    User has ability to adjust difficulty and emphasis in order to adjust the pool of poses
    that the generator takes from

    E.g generateWorkout(15, ['Beginner', 'Intermediate'], [2,3])
    => [<Pose>, <Pose>, <Pose>]

    Returns None if it can't find any poses that match the criteria
    """
    
    # RANK 1 - get all the poses that meet the criteria of difficulty and categories specified
    if not categories: # if categories None or an empty list
        all_cat_ids = db.session.query(Category.cat_id).all() # returns a list of tuples of all the ids
        categories = [category[0] for category in all_cat_ids] # converts that to a list

    all_poses = db.session.query(Pose).join(PoseCategory).filter(Pose.difficulty.in_(difficulty),
                                                            PoseCategory.cat_id.in_(categories)).all()
    
    if all_poses:
        all_poses_set = set(all_poses)
        
        diff_index = DIFFICULTIES.index(difficulty[0]) # get the index of the first thing in the difficulty list

        # RANK 2 - create a set of alternate poses that are in the category but are of lower difficulty (1 level below)
        # e.g. if Expert level, include intermediate poses. if Intermediate level, include Beginner level
        alternate_poses = []
        if diff_index > 0: # for Intermediate (index 1) and Expert (index 2) level poses
            alternate_diff = DIFFICULTIES[diff_index-1] 
            alternate_poses = db.session.query(Pose).join(PoseCategory).filter(Pose.difficulty.in_([alternate_diff]),
                                                            PoseCategory.cat_id.in_(categories)).all()
        alternate_poses_set = set(alternate_poses)

        # RANK 3 - include the basic/standard easy poses as well in the all_poses list if they're not already there
        # get the default poses to pic from depending on the difficulty level
        # for level in difficulty, get the index and pull from the default pose id list
        default_pose_ids = []
        for i in range(0,diff_index+1):
            default_pose_ids.extend(DEFAULT_POSE_IDS[i])

        default_poses = [Pose.query.get(pose_id) for pose_id in default_pose_ids] 
        default_poses_set = set(default_poses)
        # for pose in default_poses: # this adds the default poses to the overall poses set to choose from
        #     if pose not in all_poses_set:
        #         all_poses_set.add(pose)


        # start with a pose
        start_pose = random.choice(all_poses)
        workout_list = [start_pose]

        while len(workout_list) < num_poses:
            current_pose = workout_list[-1]
            next_poses = copy.deepcopy(current_pose.next_poses) # make a copy of the next poses and work from that instead
            next_pose = current_pose.getNextPose(next_poses=next_poses)
            valid_nextpose = False
            while not valid_nextpose:
                if next_pose in all_poses_set:
                    valid_nextpose = True
                elif next_pose in alternate_poses_set:
                    valid_nextpose = True
                elif next_pose in default_poses_set:
                    valid_nextpose = True
                else:
                    del next_poses[str(next_pose.pose_id)]
                    next_pose = current_pose.getNextPose(next_poses=next_poses)

            # while next_pose not in all_poses_set: # if the next pose isn't in the set of valid poses 
            #     del next_poses[str(next_pose.pose_id)] # remove that pose from the next poses dictionary
            #     next_pose = current_pose.getNextPose(next_poses=next_poses) # generate a new next pose from the updated next poses list

            workout_list.append(next_pose)

        return workout_list
    
    else:
        return None


def saveWorkout(workout_list, name=None, author=None, description=None):
    """Given a list of poses, creates an instance of a Workout object as well as the 
    associated PoseWorkout objects
    
    Can take the output from the generateWorkout function (list of Pose objects)
    Adapt to take in the json version from the server.py code?

    """
    workout = Workout(duration=len(workout_list),name=name,author=author,description=description)
    db.session.add(workout)
    db.session.commit()

    for pose in workout_list:
        poseworkout = PoseWorkout(pose_id=pose.pose_id, workout_id=workout.workout_id)
        db.session.add(poseworkout)
        db.session.commit()

    return workout


# refine weights based on a workout object
def refineWeights(workout, weight=0.1):
    """update the weights based on a saved workout"""
    # get the list of poses in that workout (list PoseWorkout objects)

    pose_workouts = workout.pose_workouts # unpack it so it's not as confusing later

    for i, pose in enumerate(pose_workouts[:-1]): # stop at the next to last pose (don't care about checking the very last pose)
        current_pose = pose.pose # pose is a PoseWorkout object with attribute pose
        next_pose = pose_workouts[i+1].pose # get the next pose in the workout
        print('refineweight - current pose', current_pose)
        print('refineweight - next pose', next_pose)

        # TODO use flag_modified instead of making a copy of it (see addnextpose route in the server.py file)
        if current_pose.next_poses:
            next_poses_copy = copy.deepcopy(current_pose.next_poses) # make a copy so I can modify its contents
        else:
            next_poses_copy = {} # if the current pose doesn't have a next_poses attribute, initialize this
        
        if str(next_pose.pose_id) in next_poses_copy: # if the pose already is in the next_poses then update its weight
            next_poses_copy[str(next_pose.pose_id)] += weight # default to add is 0.1
            # TODO: round to the nearest 0.1 decimal place??
            # print('next pose updated to new weight of', current_pose.next_poses[str(next_pose.pose_id)])
        else:
            next_poses_copy[str(next_pose.pose_id)] = 1 # add this to the next_poses with weight 1
            # print('next pose added')

        current_pose.next_poses = next_poses_copy # update next_poses with the new next_poses info
        db.session.commit()
        # print("--")


def connect_to_db(app, database_uri):
    """Connect the database to our Flask app."""

    # Configure to use our PostgreSQL database
    # production: postgresql:///yogaposes
    app.config['SQLALCHEMY_DATABASE_URI'] = database_uri
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    db.app = app
    db.init_app(app)

if __name__ == "__main__":
    # As a convenience, if we run this module interactively, it will leave
    # you in a state of being able to work with the database directly.

    from server import app
    
    PRODUCTION_DB_URI = 'postgresql:///yogaposes'
    connect_to_db(app, PRODUCTION_DB_URI)
    # db.create_all()
    print("Connected to DB.")


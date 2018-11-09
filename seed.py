from sqlalchemy import func
from model import Pose, Category, PoseCategory, connect_to_db, db
import poseparser

from server import app
# populate my database with the stuff from parseYogaFile (poseparser.py)
# read the localposefiles.txt file line by line
# for each url, run parseYogaFile, create instance of Pose, add to database

def load_poses(filename):
    """Load all the pose data taken from scraping the site to my database
    
    reads in the urls from a text file, goes to each url
    gets the relevant infomation, create a Pose object and adds to database

    also creates a Category object and adds that to the database
    """

    with open(filename) as file:
        for localurl in file: # assumes each line in the file is a url to a local file
            localurl = localurl.rstrip()
            data = poseparser.parseYogaFile(localurl)
            
            # add the pose to the database
            pose = Pose(name=data['name'], description=data['description'],
                        difficulty=data['difficulty'], benefit=data['benefits'],
                        img_url=data['imgUrl'])

            # get all the optional fields and set them as necessary
            if data.get('altNames'):
                pose.altNames = data.get('altNames')
            if data.get('sanskrit'):
                pose.sanskrit = data.get('sanskrit')
            if data.get('nextPoses'):
                pose.next_pose_str = data.get('nextPoses')
            if data.get('previousPoses'):
                pose.prev_pose_str = data.get('previousPoses')

            db.session.add(pose)
            db.session.commit()

            # get the categories that the pose belongs to and add to database as necessary
            categories = data.get('categories')
            if categories:
                categories = categories.split(" / ") # a list of the categories

                for category in categories:
                    cat_obj = Category.query.filter_by(name=category).first()
                    
                    #check to see if it it exists in database, if it doesn't add it
                    if not cat_obj:
                        cat_obj = Category(name=category)
                        db.session.add(cat_obj)
                        db.session.commit()

                    # make a PoseCategory object
                    pose_category = PoseCategory(pose_id=pose.pose_id, cat_id=cat_obj.cat_id)
                    db.session.add(pose_category)
                    db.session.commit()

def addPoseWeights():
    """
    for all Poses, converts all the next_pose_str attributes to a JSON object 
    and stores that into the next_poses attribute with the keys as the pose_id
    and the weights as the value. 

    By default the weights are all set to 1 for now

    e.g. next_poses = {pose1_id: weight1, pose2_id: weight2....}
    """

    all_poses = Pose.query.all()

    for pose in all_poses: # pose is <Pose> object
        if pose.next_pose_str:
            nextpose_dict = {}
            next_poses = pose.next_pose_str.split(',') # list of pose names 
            for next_pose in next_poses:
                next_pose_id = db.session.query(Pose.pose_id).filter(Pose.name == next_pose).first()[0]
                nextpose_dict[next_pose_id] = 1 # set all the weights to 1 for now
            pose.next_poses = nextpose_dict # add the dictionary to the next_poses attribute
            db.session.commit()
            print("added next pose for", pose)

# TO DO: refine the data a bit more, make weights better (put in seed file?)
# TO DO: incorporate yoga journal's data to help refine the data?

if __name__ == "__main__":
    connect_to_db(app)

    # In case tables haven't been created, create them
    db.create_all()

    filename1 = 'static/localposefiles.txt'
    load_poses(filename1)

    addPoseWeights()


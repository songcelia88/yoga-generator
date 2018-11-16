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

def addNewCategories():
    """Add more categories (cross referenced by Yoga Journal"""
    new_categories = {
        "Chest Opening": [10, 19, 31, 34, 78,85,114,116,160,190,170,179,192],
        "Core & Abs": [6,7,20,22,54,62,60,63,171,98,129,88,142],
        "Hip Opening":[8,9,29,35,36,72,73,92,93,94,95,76,112,111,128,129,159,168,30,161,163],
        "Restorative": [27,28,32,33,98,9,95,94,108,135,193,194,161],
        "Strengthening":[6,22,62,60,64,156,176,132,171,86,96,114,168,136,157,178,138,190,140,182,187,189],
        "Back":[118,119,10,11,17,19,20,34,60,64,72,156,176,76,78,88,114,129,144,94,21,157,178,160,169,190,131,187],
        "Digestion":[118,87,6,10,17,31,64,156,176,78,129,21,107,120,145,114,168,128,94,108,157,176,21,81,83,101,153],
        "Energy": [17,19,31,64,129,133,116,110,112,160,179,190],
        "Fatigue":[87,8,10,19,27,28,31,32,60,64,78,129,88,98,21,81,114,144,160,83,153,140,131,179,192],
        "Flexibility": [87,8,28,35,75,64,176,76,86,81,145,146,133,116,168,110,111,128,94,108,178,95,93,83,91,164,140,182,163],
        "Headaches":[87,17,32,60,64,75,76,81,21,144,108],
        "Insomnia":[87,17,20,32,34,60,64,73,75,76,21,144,108,81,83,101,153],
        "Neck Pain": [20,28,32,34,75,176],
        "Stress": [87,6,28,32,62,132,76,96,98,118,144,81,83,101,153],
        "Arms": [54,55,62,60,64,74,93,132,77,171,96,133,114,79,80,57,138,101,190,170,150,140,179,131,192],
        "Shoulders": [87,83,10,19,20,31,34,62,60,72,75,132,77,88,96,133,116,129,162,167,168,144,79,80,128,108,157,138,160,153,170,140,189]
    }

    for category, id_list in new_categories.items():
        # create new category object and commit to database
        new_category = Category(name=category)
        db.session.add(new_category)
        db.session.commit()

        # # loop through id list and create PoseCat object for each item with the id and the category id
        for pose_id in id_list:
            newPoseCat = PoseCategory(pose_id=pose_id,cat_id=new_category.cat_id)
            db.session.add(newPoseCat)
            db.session.commit()
        #  commit to database
        print("added category", category)


if __name__ == "__main__":
    PRODUCTION_DB_URI = 'postgresql:///yogaposes'
    connect_to_db(app, PRODUCTION_DB_URI)

    # In case tables haven't been created, create them
    db.create_all()

    filename1 = 'static/localposefiles.txt'
    load_poses(filename1)

    addPoseWeights()
    addNewCategories()

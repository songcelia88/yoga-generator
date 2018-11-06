from sqlalchemy import func
from model import Pose, connect_to_db, db
import poseparser

from server import app
# populate my database with the stuff from parseYogaUrl (maybe do this in the seed file)
# read the poselinks.txt file line by line
# for each url, run parseYogaUrl, create instance of Pose, add to database

def load_poses(filename):
    """Load all the pose data taken from scraping the site to my database
    
    reads in the urls from the poselinks.txt file, goes to each url
    gets the relevant infomation, create a Pose object and adds to database
    """

    with open(filename) as file:
        for url in file: # assumes each line in the file is a url
            url = url.rstrip()
            data = poseparser.parseYogaUrl(url)
            pose = Pose(name=data['name'], description=data['description'],
                        difficulty=data['difficulty'], benefit=data['benefits'],
                        img_url=data['imgUrl'])
            if data.get('altNames'):
                pose.altNames = data.get('altNames')

            db.session.add(pose)
            db.session.commit()


if __name__ == "__main__":
    connect_to_db(app)

    # In case tables haven't been created, create them
    db.create_all()

    filename = 'poselinks-sample.txt'
    load_poses(filename)
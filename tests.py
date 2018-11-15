import server
from unittest import TestCase
from model import * 
from seed import *

"""Tests for some of my code"""

class SeedTests(TestCase):
    """Testing that the seeding file worked correctly"""

    def setUp(self):
        """Stuff to run before every test"""

        # Get the Flask test client
        self.client = server.app.test_client()
        server.app.config['TESTING'] = True

        # Connect to test database
        TEST_DB_URI = 'postgresql:///yogatestdb'
        connect_to_db(server.app, TEST_DB_URI)

        # Create tables
        db.create_all()


    def tearDown(self):
        """Do at end of every test."""
        db.session.remove()
        db.drop_all()
        db.engine.dispose()


    def test_seeding(self):
        """Test that the information was seeded correctly"""

        samplefile = 'static/localposefiles-sample.txt'
        load_poses(samplefile)
        samplepose = Pose.query.get(1) # this is bridge pose according to the sample.txt file
        self.assertEqual("Bridge", samplepose.name) # test for other parameters too? like sanskrit, next poses , imgurl
        self.assertEqual("Intermediate", samplepose.difficulty) 
        self.assertIn('Setu Bandha', samplepose.sanskrit)
        self.assertIn('Corpse', samplepose.prev_pose_str)
        self.assertIn('Wheel', samplepose.next_pose_str)


    def test_initialweights(self):
        """Test that the weights for the next poses were populated correctly"""
        samplefile = 'static/localposefiles-sample.txt'
        load_poses(samplefile)
        
        allposes = Pose.query.all()
        for pose in allposes:
            pose.next_pose_str = "" # set all next_poses to blank strings for testing

        samplepose = Pose.query.get(1) # this is bridge pose according to the sample.txt file   
        samplepose.next_pose_str = "Tree,Extended Child's,Upward-Facing Dog" # manually set the next_pose_str attribute for this test
        db.session.commit()
        addPoseWeights()
        
        # expecting samplepose.next_poses = {"2": 1, "3", 1, "4", 1}
        self.assertEqual(1, samplepose.next_poses['4'])


class ModelTests(TestCase):
    """Testing that the helper functions in the model.py file works"""

    def setUp(self):
        """Stuff to run before every test"""

        # Get the Flask test client
        self.client = app.test_client()
        app.config['TESTING'] = True

        # Connect to test database
        connect_to_db(app, "postgresql:///yogatestdb")

        # Create tables
        db.create_all()

        #seed the database and add the pose weights
        samplefile = 'static/localposefiles-sample.txt'
        load_poses(samplefile)
        allposes = Pose.query.all()
        for pose in allposes:
            pose.next_pose_str = "Bridge" # set all next_poses to Bridge for testing

        bridge = Pose.query.get(1) # this is bridge pose according to the sample.txt file   
        bridge.next_pose_str = "Tree,Upward-Facing Dog" # manually set the next_pose_str attribute for this test
        db.session.commit()
        addPoseWeights()

    def tearDown(self):
        """Do at end of every test."""
        db.session.remove()
        db.drop_all()
        db.engine.dispose()
    
    def test_nextPose(self):
        """Test the next pose function for the Pose object"""
        samplepose = Pose.query.get(1)
        next_pose = samplepose.getNextPose()

        self.assertIn(next_pose.pose_id, [2,3]) # [1. Bridge, 2. Tree, 3. Extended Child's, 4. Upward Facing Dog]


    def test_generateWorkout(self):
        """Test the generate workout function in the model.py file """
        # select a number of poses
        num_poses = 5
        workout_list = generateWorkout(num_poses)
        print(workout_list)
        self.assertEqual(len(workout_list), 5)
        self.assertIs(type(workout_list[0]), Pose)


if __name__ == "__main__":
    import unittest
    unittest.main()
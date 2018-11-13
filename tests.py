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
        samplefile = 'static/localposefiles-sample.txt'
        load_poses(samplefile)
        samplepose = Pose.query.get(1) # this is bridge pose according to the sample.txt file
        self.assertEqual(samplepose.name, "Bridge") # test for other parameters too? like sanskrit, next poses , imgurl
        self.assertEqual(samplepose.difficulty, "Intermediate")

    # test populating the weights
        # run the loadposes function
        # run the add pose weights function
        # query the database to see that the output is expected

# class ModelTests(TestCase):
#     """Testing that the helper functions in the model.py file works"""

#     def setUp(self):
#         """Stuff to run before every test"""

#         # Get the Flask test client
#         self.client = app.test_client()
#         app.config['TESTING'] = True

#         # Connect to test database
#         connect_to_db(app, "postgresql:///yogatestdb")

#         # Create tables
#         db.create_all()

#         #seed the database and add the pose weights

#     def tearDown(self):
#         """Do at end of every test."""

#         db.session.remove()
#         db.drop_all()
#         db.engine.dispose()
    
#     # test the get next pose function of the Pose object
#         # select a pose (a known one)
#         # check that the next pose is one of 3 that are know to be in the next poses field
#         # check that the weights are correct?

#     # test the generate Workout function
#         # select a number of poses
#         # check that it returns a list of Pose Objects and the length of the list is correct


if __name__ == "__main__":
    import unittest
    unittest.main()
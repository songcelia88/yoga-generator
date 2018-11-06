from flask_sqlalchemy import SQLAlchemy

# This is the connection to the PostgreSQL database; we're getting this through
# the Flask-SQLAlchemy helper library. On this, we can find the `session`
# object, where we do most of our interactions (like committing, etc.)

db = SQLAlchemy()

##############################################################################
# Model classes

class Pose(db.Model):
    __tablename__ = "poses"

    pose_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    name = db.Column(db.String(100), nullable=False, unique=True) # required and unique
    description = db.Column(db.String(1000))
    difficulty = db.Column(db.String(20), nullable=False)
    altNames = db.Column(db.String(100), nullable=True)
    benefit = db.Column(db.String(1000), nullable=True)
    img_url = db.Column(db.String(200), nullable=False)

    pose_seqs = db.relationship('PoseSeq')

    def __repr__(self):
        """Print out the Pose object nicely"""
        return "<Pose pose_id={}, name={}>".format(self.pose_id, self.name)


class Sequence(db.Model):
    __tablename__ = "sequences"

    seq_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    duration = db.Column(db.Integer, nullable=False) # in minutes

    pose_seqs = db.relationship('PoseSeq')

    def __repr__(self):
        """Print out the Sequence Object nicely"""
        return "<Sequence seq_id={}, duration={}>".format(self.seq_id, self.duration)


class PoseSeq(db.Model):
    __tablename__ = "poseseqs"
    poseseq_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    pose_id =  db.Column(db.Integer, db.ForeignKey('poses.pose_id'), nullable=False)
    seq_id = db.Column(db.Integer, db.ForeignKey('sequences.seq_id'), nullable=False)

    sequence = db.relationship('Sequence')
    pose = db.relationship('Pose')

    def __repr__(self):
        """Print out the Pose-Sequence object nicely"""
        return "<PoseSeq pose name = {}, seq_id = {}".format(self.pose.name, self.seq_id)


##############################################################################
# Helper functions

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
    db.create_all() # create tables so I can work with them
    print("Connected to DB.")
"""
Just a standalone model so I can mess around with some SQLAlchemy stuff, like JSON
data types

"""

from flask_sqlalchemy import SQLAlchemy
from sqlalchemy.dialects.postgresql import JSON
from flask import Flask

app = Flask(__name__)
app.secret_key = "ABC"

db = SQLAlchemy()


##############################################################################
# Model classes

class Cat(db.Model):
    __tablename__ = "cats"

    cat_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    toys = db.Column(JSON) # doesn't seem to be strict, I can make this a string or number as well...

    def __repr__(self):
        return "<Cat id={}>".format(self.cat_id)

##############################################################################
# Helper functions

def connect_to_db(app):

    app.config['SQLALCHEMY_DATABASE_URI'] = 'postgresql:///cattestdb'
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    db.app = app
    db.init_app(app)

if __name__ == "__main__":

    # from server import app
    connect_to_db(app)
    db.create_all()
    print("Connected to DB.")
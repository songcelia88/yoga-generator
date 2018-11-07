from jinja2 import StrictUndefined

from flask import Flask, render_template, redirect, request, flash, session
from flask_debugtoolbar import DebugToolbarExtension

from model import db, Pose, Sequence, PoseSeq, PoseCategory, Category

app = Flask(__name__)

# Required to use Flask sessions and the debug toolbar
app.secret_key = "ABC"
app.jinja_env.undefined = StrictUndefined

@app.route('/')
def homepage():
    """display homepage"""
    return "<html><body><h1>Hello</h1></body></html>"


if __name__ == "__main__":
    # We have to set debug=True here, since it has to be True at the
    # point that we invoke the DebugToolbarExtension
    app.debug = True

    # Use the DebugToolbar
    DebugToolbarExtension(app)

    app.run(host='0.0.0.0')
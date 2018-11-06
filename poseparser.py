from bs4 import BeautifulSoup

def parseYoga(filename):
    """Function that takes an html page from Pocket Yoga and returns a dictionary
    of details on that yoga pose
    
    Returns a dictionary of pose data with the following keys:
    name, description, difficulty, altNames, categories, benefits, imgUrl, previousPoses,
    nextPoses
    
    """

    with open(filename) as file:
        htmlsoup = BeautifulSoup(file, "html.parser")

    data = {}

    # get the pose name
    data['name'] = htmlsoup.select(".poseDescription h3")[0].get_text()

    # get the pose description
    descStr = htmlsoup.find(string="Description:")
    data['description'] = descStr.parent.next_sibling.get_text()

    # get the pose difficulty
    diffStr = htmlsoup.find(string="Difficulty:")
    data['difficulty'] = diffStr.parent.next_sibling.get_text()

    # get the alt name (nullable in the database)
    altStr = htmlsoup.find(string="Alt. Name:")
    if altStr: #if it exists
        altText = altStr.parent.next_sibling.get_text()
        altNames = altText.split(" / ")
        data['altNames'] = altNames

    # get the category 
    catStr = htmlsoup.find(string="Category:")
    catText = catStr.parent.next_sibling.get_text()
    data['categories'] = catText.split(" / ")

    # get the benefits
    benStr = htmlsoup.find(string="Benefits:")
    data['benefits'] = benStr.parent.next_sibling.get_text()

    #get the pose image filename
    imgSrc = htmlsoup.select('#poseImg')[0]['src']
    imgSrc = imgSrc.split('/')
    data['imgUrl'] = imgSrc[-1]

    # get the previous poses (if they exist)
    prevTitle = htmlsoup.find(string="Previous Poses")
    previousPoses = []
    if prevTitle:
        prevPoseList = prevTitle.parent.next_sibling.contents # in the form [<li><a></a><li>, <li><a></a><li>]
        for element in prevPoseList: # each element is in the form <li><a></a></li>
            poseTitle = element.contents[0]['title'] #take the first child
            previousPoses.append(poseTitle)
    data['previousPoses'] = previousPoses

    # get the next poses (if they exist)
    nextTitle = htmlsoup.find(string="Next Poses")
    nextPoses = []
    if nextTitle:
        nextPoseList = nextTitle.parent.next_sibling.contents # in the form [<li><a></a><li>, <li><a></a><li>]
        for element in nextPoseList: # each element is in the form <li><a></a></li>
            poseTitle = element.contents[0]['title'] #take the first child
            nextPoses.append(poseTitle)
    data['nextPoses'] = nextPoses

    return data

if __name__ == "__main__":
    # works on one pose page
    # TO DO: download all the pocket yoga pages and pictures (wget -p -k URL?)
    # TO DO: run the parser over all the downloaded files
    # TO DO: create entries in database with the information that the parser outputs
    pose1 = parseYoga("Yoga_Pose_Caterpillar.html")
    pose2 = parseYoga("Yoga_Pose_Box.html")
    pose3 = parseYoga("Yoga_Pose_Bound Angle.html")


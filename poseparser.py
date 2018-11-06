from bs4 import BeautifulSoup
import requests

def getPoseLinks(filename):
    """Get all the hperlinks from the all poses page and put into a text file"""

    with open(filename) as file:
        htmlsoup = BeautifulSoup(file, "html.parser")

    # grab all the link elements in the posesDisplay class and make a list of all the urls
    posesDisplay = htmlsoup.select('.posesDisplay li a')
    # poseUrls = [link['href'] for link in posesDisplay]

    # write into text file
    with open("poselinks.txt", "a") as file:
        for link in posesDisplay:
            poseUrl = link['href']
            file.write(poseUrl + '\n')
    

def parseYogaUrl(url):
    """Function that takes a url from Pocket Yoga and returns a dictionary
    of details on that yoga pose
    
    Returns a dictionary of pose data with the following keys:
    name, description, difficulty, altNames, categories, benefits, imgUrl, previousPoses,
    nextPoses

    Also downloads the associated image and saves to the static folder
    
    """

    res = requests.get(url)
    print('response is', res)
    htmlsoup = BeautifulSoup(res.content, 'html.parser')
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

    #get the pose image url
    imgSrc = htmlsoup.select('#poseImg')[0]['src'] # e.g. "./images/poses/warrior..."
    baseUrl = 'http://www.pocketyoga.com'
    fullUrl = baseUrl + imgSrc[1:] # exclude the . on the imgSrc string
    # print('fullUrl is ', fullUrl)

    imgSrc = imgSrc.split('/')
    data['imgUrl'] = "static/" + imgSrc[-1] # e.g. "static/filename.jpg"

    # download image and save to my static folder
    imgRes = requests.get(fullUrl)
    with open(data['imgUrl'], 'wb') as f: 
        f.write(imgRes.content)
        print("downloaded picture", data['imgUrl'])


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

    # print out a status message so I know what's going on
    print('got the data for', data['name'])

    return data

# populate my database with the stuff from parseYogaUrl (maybe do this in the seed file)
# read the poselinks.txt file line by line
# for each url, run parseYogaUrl, create instance of Pose, add to database

if __name__ == "__main__":

    # populate the poselinks.txt file with all the links (run only once)
    with open("poselinks.txt", 'w') as file:
        file.write('') # clear the file first in case there is anything else there

    for i in range(1,8):
        url = "yoga-pages/poses-pg" + str(i) + ".html"
        getPoseLinks(url)

###############################################################################

# old functions that I probably won't use

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

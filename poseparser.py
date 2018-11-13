from bs4 import BeautifulSoup
import requests

def getPoseLinks(filename):
    """Get all the hperlinks from the all poses page and put into a text file"""

    with open(filename) as file:
        htmlsoup = BeautifulSoup(file, "html.parser")

    # grab all the link elements in the posesDisplay class and make a list of all the urls
    posesDisplay = htmlsoup.select('.posesDisplay li a')

    # write into text file
    with open("poselinks.txt", "a") as file:
        for link in posesDisplay:
            poseUrl = link['href']
            file.write(poseUrl + '\n')
    

def downloadYogaPages(filename):
    """Goes through all the urls in the file and downloads the html and saves
    them for parsing later on

    you only need to run this once to download the files and images

    htmls saved to folder: static/yogaposes
    imgs saved to folder: static/img
    """

    with open(filename) as file:
        for url in file:  # assumes each line in the file is a url
            url = url.rstrip()
            res = requests.get(url)
            print('response is', res)
            
            # get the name to name the file
            localAddress = "static/yogaposes/" + url[31:] #take off the 'http://www.pocketyoga.com/' part in the url
            with open("static/localposefiles.txt", "a") as localfile: # save the local address to text file
                localfile.write(localAddress + '\n')
                
            # save content in html file
            with open(localAddress, "wb") as localhtml: 
                localhtml.write(res.content) # res.text is a string, res.content is a byte string
                print("saved html")

            # save the image from that page
            htmlsoup = BeautifulSoup(res.content, 'html.parser')
            imgSrc = htmlsoup.select('#poseImg')[0]['src'] # e.g. './images/poses/awkward.png'
            fullUrl = 'http://www.pocketyoga.com' + imgSrc[1:] # exclude the . on the imgSrc string
            imgRes = requests.get(fullUrl) # get the image
            localImgUrl = "static/img/" + imgSrc.split('/')[-1] # e.g. 'static/img/awkward.png'

            with open(localImgUrl, 'wb') as f: # open file option b means binary mode e.g. images
                f.write(imgRes.content)
                print("downloaded picture", localImgUrl)


def parseYogaFile(filename):
    """Function that takes a local html file and returns a dictionary
    of details on that yoga pose
    
    Returns a dictionary of pose data with the following keys:
    name, sanskrit, description, difficulty, altNames, categories, benefits, imgUrl, previousPoses,
    nextPoses

    Use this in the seed.py file to fill the database
    """
    with open(filename) as file:
        htmlsoup = BeautifulSoup(file, "html.parser")
    
    data = {}

    # get the pose name
    data['name'] = htmlsoup.select(".poseDescription h3")[0].get_text()

    # get the sanskrit name
    sanskrit = htmlsoup.select(".poseDescription h4")
    if sanskrit:
        data['sanskrit'] = sanskrit[0].get_text()

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
        data['altNames'] = altText

    # get the category
    catStr = htmlsoup.find(string="Category:")
    catText = catStr.parent.next_sibling.get_text()
    data['categories'] = catText

    # get the benefits
    benStr = htmlsoup.find(string="Benefits:")
    data['benefits'] = benStr.parent.next_sibling.get_text()

    #get the pose image url
    imgSrc = htmlsoup.select('#poseImg')[0]['src'] # e.g. "./images/poses/warrior..."
    imgSrc = imgSrc.split('/')
    data['imgUrl'] = "static/img/" + imgSrc[-1] # e.g. "static/filename.png"

    # get the previous poses (if they exist), store as a string for now
    prevTitle = htmlsoup.find(string="Previous Poses")
    previousPoses = ""
    if prevTitle:
        prevPoseList = prevTitle.parent.next_sibling.contents # in the form [<li><a></a><li>, <li><a></a><li>]
        for element in prevPoseList: # each element is in the form <li><a></a></li>
            poseTitle = element.contents[0]['title'] # take the first child
            previousPoses += poseTitle + "," # e.g. previousPoses = "Warrior 1, Warrior 2, Downward Dog,"
    
    data['previousPoses'] = previousPoses[:-1] # chop off the last comma

    # get the next poses (if they exist), store as a string for now
    nextTitle = htmlsoup.find(string="Next Poses")
    nextPoses = ""
    if nextTitle:
        nextPoseList = nextTitle.parent.next_sibling.contents # in the form [<li><a></a><li>, <li><a></a><li>]
        for element in nextPoseList: # each element is in the form <li><a></a></li>
            poseTitle = element.contents[0]['title'] #take the first child
            nextPoses += poseTitle + "," # e.g. nextPoses = "Warrior 1, Warrior 2, Downward Dog,"

    data['nextPoses'] = nextPoses[:-1] # chop off the last comma

    # print out a status message so I know what's going on
    print('got the data for', data['name'])

    return data


if __name__ == "__main__":

    # populate the poselinks.txt file with all the links (run only once)
    # with open("poselinks.txt", 'w') as file:
    #     file.write('') # clear the file first in case there is anything else there

    # for i in range(1,8):
    #     url = "static/yoga-pages/poses-pg" + str(i) + ".html"
    #     getPoseLinks(url)

    filename1 = "static/yoga-pages/poselinks.txt" # the first 100 urls
    filename2 = 'static/yoga-pages/poselinks-2.txt' # the second half of the urls
    sample = "static/yoga-pages/poselinks-sample.txt" # a sample of just 5 links for testing
    downloadYogaPages(filename1)


###############################################################################

# old functions that I probably won't use

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

    # get the sanskrit name
    sanskrit = htmlsoup.select(".poseDescription h4")
    if sanskrit:
        data['sanskrit'] = sanskrit[0].get_text()

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
        data['altNames'] = altText

    # get the category
    catStr = htmlsoup.find(string="Category:")
    catText = catStr.parent.next_sibling.get_text()
    data['categories'] = catText

    # get the benefits
    benStr = htmlsoup.find(string="Benefits:")
    data['benefits'] = benStr.parent.next_sibling.get_text()

    #get the pose image url
    imgSrc = htmlsoup.select('#poseImg')[0]['src'] # e.g. "./images/poses/warrior..."
    baseUrl = 'http://www.pocketyoga.com'
    fullUrl = baseUrl + imgSrc[1:] # exclude the . on the imgSrc string
    # print('fullUrl is ', fullUrl)

    imgSrc = imgSrc.split('/')
    data['imgUrl'] = "static/" + imgSrc[-1] # e.g. "static/filename.png"

    # download image and save to my static folder
    imgRes = requests.get(fullUrl)
    with open(data['imgUrl'], 'wb') as f: # open file option b means binary mode e.g. images
        f.write(imgRes.content)
        print("downloaded picture", data['imgUrl'])


    # get the previous poses (if they exist), store as a string for now
    prevTitle = htmlsoup.find(string="Previous Poses")
    previousPoses = ""
    if prevTitle:
        prevPoseList = prevTitle.parent.next_sibling.contents # in the form [<li><a></a><li>, <li><a></a><li>]
        for element in prevPoseList: # each element is in the form <li><a></a></li>
            poseTitle = element.contents[0]['title'] # take the first child
            previousPoses += poseTitle + "," # e.g. previousPoses = "Warrior 1, Warrior 2, Downward Dog,"
    
    data['previousPoses'] = previousPoses[:-1] # chop off the last comma

    # get the next poses (if they exist), store as a string for now
    nextTitle = htmlsoup.find(string="Next Poses")
    nextPoses = ""
    if nextTitle:
        nextPoseList = nextTitle.parent.next_sibling.contents # in the form [<li><a></a><li>, <li><a></a><li>]
        for element in nextPoseList: # each element is in the form <li><a></a></li>
            poseTitle = element.contents[0]['title'] #take the first child
            nextPoses += poseTitle + "," # e.g. nextPoses = "Warrior 1, Warrior 2, Downward Dog,"

    data['nextPoses'] = nextPoses[:-1] # chop off the last comma

    # print out a status message so I know what's going on
    print('got the data for', data['name'])

    return data


def oldParseYoga(filename):
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

    # get the sanskrit name
    data['sanskrit'] = htmlsoup.select(".poseDescription h4")[0].get_text()

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

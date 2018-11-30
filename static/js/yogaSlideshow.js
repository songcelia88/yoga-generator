////// Code for the Slideshow part of the Workout page //////////////
// https://codepen.io/SitePoint/pen/WwqvqB (Adapted from this code)
// https://www.w3schools.com/howto/howto_js_slideshow.asp

//TODO: have it save the current active thing in the workout? right now it just starts over

// get all the slides and the slider thumbnails
const slides = document.querySelectorAll('#slides .slide');
const sliderThumbnails = document.querySelectorAll('.slider .slider-img')

// show the first slide on load
let currentSlide = 0;
slides[currentSlide].style.display='block' //show the first slide
sliderThumbnails[currentSlide].classList.add('active'); //highlight the first slide thumbnail

//show the first 5 thumbnails/poses
for (let i=currentSlide; i<currentSlide+5;i++){
    sliderThumbnails[i].classList.add('displayed');
}

let slideInterval;
const SLIDETIMING = 2000;
let playing = false;
const pauseButton = document.getElementById('play-pause');
const next = document.getElementById('next');
const previous = document.getElementById('previous');
const sliderPrev = document.getElementById('slider-prev');
const sliderNext = document.getElementById('slider-next');

function nextSlide(){
    if(currentSlide == slides.length-1){
        //if we reach the last slide keep on that slide
        goToSlide(currentSlide); 
    }
    else{
        goToSlide(currentSlide+1);
    }
}

function previousSlide(){
    if(currentSlide == 0){
        //if we are on the first slide, then, stay on that slide
        goToSlide(currentSlide);
    }
    else{
        goToSlide(currentSlide-1);
    }
}

function goToSlide(n){
    slides[currentSlide].style.display = 'none'; //change the attribute to display: none
    sliderThumbnails[currentSlide].classList.remove('active') //remove the thumbnail highlight

    currentSlide = n //update the currentSlide
    slides[currentSlide].style.display = 'block'; //change the new current slide attribute to display:block
    sliderThumbnails[currentSlide].classList.add('active') //add the thumbnail highlight to the new slide
    
    //check slide index of active slide and shift thumbnails as needed
    activeSlideIndex = parseInt(sliderThumbnails[currentSlide].dataset.slideindex);
    let displayedThumbnails = document.querySelectorAll('.slider-img.displayed');
    let firstThumbnailIndex = parseInt(displayedThumbnails[0].dataset.slideindex)
    let lastThumbnailIndex = parseInt(displayedThumbnails[displayedThumbnails.length-1].dataset.slideindex);

    if(activeSlideIndex > lastThumbnailIndex){
        shiftThumbnailsRight();
    }
    else if(activeSlideIndex < firstThumbnailIndex){
        shiftThumbnailsLeft();
    }
}

function pauseSlideshow(){
    pauseButton.innerHTML = '<i class="fas fa-play-circle fa-2x"></i>'; // play character
    playing = false;
    clearInterval(slideInterval);
}

function playSlideshow(){
    pauseButton.innerHTML = '<i class="fas fa-pause-circle fa-2x"></i>'; // pause character
    playing = true;
    slideInterval = setInterval(nextSlide,SLIDETIMING);
}

function shiftThumbnailsLeft(){
    //used with the previous < button for the thumbnails
    //function to move the slider thumbnails over to the left
    let displayedThumbnails = document.querySelectorAll('.slider-img.displayed');
    
    //get the slide index of the first shown thumbnail
    let firstThumbnailIndex = parseInt(displayedThumbnails[0].dataset.slideindex)

    //show the thumbnail before the current first thumbnail
    let prevThumbnailIndex = firstThumbnailIndex-1
    // only slide to the left if the index is greater than 0
    if (prevThumbnailIndex >= 0){
        displayedThumbnails[displayedThumbnails.length-1].classList.remove('displayed'); //hide the last thumbnail
        let queryString = '[data-slideindex="' + prevThumbnailIndex + '"]';
        document.querySelector(queryString).classList.add('displayed')
    }
}

function shiftThumbnailsRight(){
    //used with the next > button for the thumbnails
    //function to move the slider thumbnails over to the right
    let displayedThumbnails = document.querySelectorAll('.slider-img.displayed');
    
    //get the slide index of the last shown thumbnail
    let lastThumbnailIndex = parseInt(displayedThumbnails[displayedThumbnails.length-1].dataset.slideindex); 
    
    //show the thumbnail after the current last thumbnail
    let nextThumbnailIndex = lastThumbnailIndex + 1
    //only slide to the right if the index is less than the total number of slides
    if(nextThumbnailIndex < slides.length){ 
        displayedThumbnails[0].classList.remove('displayed'); //hide the first thumbnail
        let queryString = '[data-slideindex="' + nextThumbnailIndex + '"]';
        document.querySelector(queryString).classList.add('displayed')
    }
}

//event listeners for the player control buttons
pauseButton.addEventListener('click', (evt)=>{
    if(playing){ pauseSlideshow(); }
    else{ playSlideshow(); }
});

next.addEventListener('click', (evt)=>{
    pauseSlideshow();
    nextSlide();
});

previous.addEventListener('click', (evt)=>{
    pauseSlideshow();
    previousSlide();
});

//event listeners for the slider controls/thumbnails
for (let i=0;i<sliderThumbnails.length; i++){
    sliderThumbnails[i].addEventListener('click', (evt)=>{ 
        pauseSlideshow();
        slideIndex = parseInt(evt.target.dataset.slideindex);
        goToSlide(slideIndex)
    });
}

sliderNext.addEventListener('click', (evt)=>{
    shiftThumbnailsRight();

});

sliderPrev.addEventListener('click', (evt)=>{
    shiftThumbnailsLeft();
});

// hide the play button if the timingOption is untimed
const timingOption = document.getElementById('timingOption')

if(timingOption.dataset.info == "Untimed"){
    timingOption.style.display = "none"
}

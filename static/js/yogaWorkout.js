
function createWorkoutHandler() {
    // event handler for the create workout form on the homepage
    $('#create-workout-form').on('submit', (evt)=>{
        evt.preventDefault();
        const data = { 'num_poses': $('#num_poses').val() };

        // send AJAX request to server to get the generated workout
        $.ajax({
            method: "GET",
            url: "/workout.json",
            data: data,
            success: (results)=>{
                //console.log("success")
                displayWorkout(results['workout_list'])
                document.getElementById('errorMessage').innerHTML = ""
            },
            error: (xhr, status, error) =>{
                document.getElementById('errorMessage').innerHTML = `Error creating workout
                                                                    please try again`
            }
        });

        document.getElementById('errorMessage').innerHTML = "Generating Workout...."

    }); //end event handler
}

function saveWorkoutHandler(){
    //event handler for the save workout button on the page
    $('#save-workout-btn').on('click', (evt)=>{

        // Do some form validation here

        // unpack the data from the form
        let data = {
            'workoutName': document.getElementById('workoutName').value,
            'userName': document.getElementById('userName').value,
            'description': document.getElementById('description').value
        }
        console.log(data)

        $.ajax({
            method: "POST",
            url: "/saveworkout",
            data: data,
            success: (results)=>{
                console.log("workout saved")
                let resultText = ""
                if (results['isInSession']) {
                    resultText = "Your Workout was Saved!"
                }
                else {
                    resultText = "Please create a workout first!"
                }
                
                // clear message in modal
                document.getElementById('errorMessageModal').innerHTML = ""
                // close modal then display message
                $('#saveWorkoutModal').modal('hide')
                document.getElementById('errorMessage').innerHTML = resultText
            },
            error: (xhr, status, error) =>{
                // display message in the modal itself
                document.getElementById('errorMessageModal').innerHTML = `Error saving workout
                                                                    please try again`
            }
        }); //end ajax request

    }); //end event handler
}

function displayWorkout(workoutList){
    //display all the poses and their pictures and names
    // expects workoutList to be an list
    // workoutList = [{'pose_id' : 184, 'imgurl':'static/img/downward-dog.png', 'name': 'Downward Dog'},
    //                  {...}, {...}]
    // displays the names of the poses and the pictures with links to the pose info
    
    document.getElementById('workout-title').innerHTML = "Your Workout" //display the title
    
    yogaposesdiv = document.getElementById('yogaposes');
    yogaposesdiv.innerHTML = "" //clear the div first
    
    // display all the poses and their names by inserting div elements into yogaposes div
    for (let i=0; i<workoutList.length; i++){
        currentpose = workoutList[i];
        posediv = document.createElement('div');
        posediv.innerHTML = `<h3>
                                <a href="/pose/${currentpose['pose_id']}">
                                    ${i+1}. ${currentpose['name']}<br>
                                    <img src=${currentpose['imgurl']}>
                                <a>
                            </h3>`;
        yogaposesdiv.appendChild(posediv)
    }

}

function exitWorkoutHandler(){
    // exits the workout and clears it from the session (redirect back to the homepage)
    $('#exit-workout-btn').on('click', (evt)=>{

        $.ajax({
            method: "POST",
            url: "/exitworkout",
            data: {},
            success: (results) =>{
                //do I need to do anything here? go to the homepage?
                window.location.pathname = '/';
                console.log('success in clearing workout')

            },
            error: (xhr, status, error) =>{
                document.getElementById('errorMessage').innerHTML = `Error exiting out of workout. 
                                                                    Please try again`
            }
        }); //end ajax call

    }); //end click event listener
}

//call the handlers
saveWorkoutHandler();
exitWorkoutHandler();

////// Code for the Slideshow part of the Workout page //////////////

const slides = document.querySelectorAll('#slides .slide');
// show the first slide on load
let currentSlide = 0;
slides[currentSlide].style.display='block'
// let slideInterval = setInterval(nextSlide,2000); //nextSlide is a function
let slideInterval;
let playing = false;
const pauseButton = document.getElementById('play-pause');
const next = document.getElementById('next');
const previous = document.getElementById('previous');

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
    currentSlide = n //update the currentSlide
    slides[currentSlide].style.display = 'block'; //change the new current slide attribute to display:block
}

function pauseSlideshow(){
    pauseButton.innerHTML = '<i class="fas fa-play-circle fa-2x"></i>'; // play character
    playing = false;
    clearInterval(slideInterval);
}

function playSlideshow(){
    pauseButton.innerHTML = '<i class="fas fa-pause-circle fa-2x"></i>'; // pause character
    playing = true;
    slideInterval = setInterval(nextSlide,2000);
}

//event handlers for the player control buttons
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

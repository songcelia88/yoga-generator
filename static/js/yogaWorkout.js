
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
    $('#save-workout').on('click', (evt)=>{

        $.ajax({
            method: "POST",
            url: "/saveworkout",
            data: {},
            success: (results)=>{
                console.log("workout saved")
                let resultText = ""
                if (results['isInSession']) {
                    resultText = "Your Workout was Saved!"
                }
                else {
                    resultText = "Please create a workout first!"
                }
                document.getElementById('errorMessage').innerHTML = resultText
            },
            error: (xhr, status, error) =>{
                document.getElementById('errorMessage').innerHTML = `Error saving workout
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

//call the handlers
// createWorkoutHandler();
saveWorkoutHandler();
// event handlers for admins to edit pose data in the database
// Includes functions:
// changing the weights of the next poses and adding next poses (and their corresponding weights)
// add new categories and adding poses to those categories

function editWeightsHandler(){
    // This function makes the weights editable fields when the user clicks on the
    // edit weights button
    $('#edit-weight-btn').on('click', (evt) => {
        // change the editable fields into input fields
        let editableFields = document.getElementsByClassName('editable-field')
        for (let i=0; i<editableFields.length; i++){
            let value = parseInt(editableFields[i].innerHTML);
            editableFields[i].innerHTML = `<input type=number value=${value}>`
        }
        $('#edit-weight-btn').hide();
        $('#save-weight-btn').show();

    });
}

function saveWeightsHandler(){
    // This function takes the weights that are input in the editable fields and 
    // saves those to the database

    // TO DO form validation: check for blank fields and invalid entries

    $('#save-weight-btn').on('click', (evt) => {
        // get the data to send to the server: need the original pose id, next pose ids and new weights
        const pose_id = $('#pose-title').data('poseid')
        const posefields = $('.next-poses') // get all the next pose fields
        let next_poses = {} // {pose_id: weight, pose_id: weight ... }
        for (let i=0; i<posefields.length; i++){
            let nextposeid = posefields[i].getAttribute('data-poseid')
            let weight = parseFloat(posefields[i].lastElementChild.firstElementChild.value)
            next_poses[nextposeid] = weight
        }
        // console.log(next_poses)

        let data = {
            'pose_id': pose_id,
            'next_poses': next_poses // {pose_id: weight, pose_id: weight ... }
        };
        console.log("data sent is")
        console.log(data)

        // Ajax call to the server to save to database
        $.ajax({
            method: "POST",
            url: "/saveweights.json",
            data: JSON.stringify(data),
            contentType: 'application/json',
            success: (results) => {

                //update the page with the new weights
                for (let i=0; i<posefields.length; i++){
                    let nextposeid = posefields[i].getAttribute('data-poseid')
                    let weight = results[nextposeid]
                    posefields[i].lastElementChild.innerHTML = weight
                }
                $('#edit-weight-btn').show();
                $('#save-weight-btn').hide();
                $('#error-message').html("Saved Weights");
            },
            error: (xhr, status, error) => {
                $('#error-message').html("error contacting server to save weights. Try again");
            }
        }); //end ajax call

    }); // end event listener

} //end event handler function

function removeNextPoseHandler(){
    // This function takes pose id and weight that the user inputs in the form and removes this from
    // the next poses field for that pose in the database

    $('#add-nextpose-form').on('submit', (evt) =>{
        evt.preventDefault();

        //get the data to send
        const pose_id = $('#pose-title').data('poseid')

    });
}

editWeightsHandler()
saveWeightsHandler()
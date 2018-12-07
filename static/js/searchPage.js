// function to fill in the search fields if there is info in the url
// https://stackoverflow.com/questions/901115/how-can-i-get-query-string-values-in-javascript

function fillSearchBar(){
    const urlParams = new URLSearchParams(window.location.search);
    const keyword = urlParams.get('keyword');
    const categories = urlParams.getAll('categories') // need to convert these to numbers?
    const difficulties = urlParams.getAll('difficulty');

    // fill in keyword field
    document.getElementById('keyword').value = keyword

    // fill in the categories that were selected
    categoryElements = document.getElementsByName('categories');
    for (let category of categoryElements){
        if (categories.includes(category.value)){
            category.checked = true;
        }
    }

    // fill in the difficulties that were selected
    difficultyElements = document.getElementsByName('difficulty');
    for (let difficulty of difficultyElements){
        if(difficulties.includes(difficulty.value)){
            difficulty.checked = true;
        }
    }
}

function showCategoryFilters(){
    // function to show or hide the category filters
    const categoryButton = document.getElementById('category-dropdown')
    let showing = true;
    const categoryFields = document.getElementById('categories-group')
    categoryButton.addEventListener('click', (evt)=>{
        //console.log("clicked!")
        if (showing){
            categoryFields.style.display="none";
            showing = false;
        }
        else{
            categoryFields.style.display="block";
            showing=true
        }
    });
}

function showDifficultyFilters(){
    // function to show or hide the category filters
    const difficultyButton = document.getElementById('difficulty-dropdown')
    let showing = true;
    const difficultyFields = document.getElementById('difficulty-group')
    difficultyButton.addEventListener('click', (evt)=>{
        //console.log("clicked!")
        if (showing){
            difficultyFields.style.display="none";
            showing = false;
        }
        else{
            difficultyFields.style.display="block";
            showing=true
        }
    });
}

fillSearchBar();
showCategoryFilters();
showDifficultyFilters()
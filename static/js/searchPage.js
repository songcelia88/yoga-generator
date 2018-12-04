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
// function to update 
// getting facet counts:



fillSearchBar();
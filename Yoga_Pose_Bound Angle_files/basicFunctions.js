function slider (interval) {
    var slides;
    var slideCount;
    var cnt;
    var i;
    var timer = null;
    
    function run(slideIndex) {
        // hide old image
        $(slides[i]).fadeOut(1000);
        $(cnt[i]).removeClass('active');
        i++;
        
        // if clicked on a slide set to that index
        if(slideIndex != undefined) {
            i = slideIndex;
        }
        
        // reached the end of the slider, reset to first
        if(i >= slideCount) {
            i = 0;
        }
        
        // show new image
        $(cnt[i]).addClass('active');
        $(slides[i]).fadeIn(1000);
        
        timer = setTimeout(run, interval);
    }
    
    slides = $('#slider').children();
    slideCount = slides.length;

    // create structure for buttons
    $('#slider').after(function() {
        var str = "<ul id=\"counter\">";
        for(var j = 0; j < slideCount; j++)
        {
            str += "<li><div></div></li>";  // defined div in css to contain the inactive button image
        }
        str += "</ul>";
        return str;
    });
    
    cnt = $('#counter li div');
    
    // add click event to go to that slide
    $(cnt).each( function(index) {
        $(this).click( function() {
            clearTimeout(timer);  // removes current infinite loop
            run(index);
        });
    });
    
    // display slide active button image
    $(cnt[0]).addClass('active');
    i = 0;
    
    setTimeout(run, interval);
};


/*  Looks at all img tags on the page and if the machine is a retina
 *  display, it replaces the image with a high resolution image.  High resolution image should
 *  have same name as low resolution image with the addition of @2x at the end.
 *  INPUT:  none
 *  RETURN: none
 */
function hiResConversion () {
    
    if(window.devicePixelRatio >= 2) {
        $('img').each(function(i, e){
            var src = $(e).attr('src');
            var ext = /(\.\w+)$/.exec(src)[0];
            $(e).attr('src', src.replace(ext, '@2x' + ext));
        });
    }
};


/*  Looks at all img tags on the page and if the machine is no longer retina
 *  display, it replaces the high resolution images with a low resolution image.  This runs when 
 *  the user switch to a lower resolution monitor.
 *  INPUT:  none
 *  RETURN: none
 */
function lowResConversion () {
    $('img').each(function(i, e){
        var src = $(e).attr('src');
        $(e).attr('src', src.replace('@2x', ''));
    });
};


function loadStates (cat, sub, dif, sch) {
    //$('#mainSection h1').text("sch:" + sch);
    
    // valid values for categories are 1-7.  Value bound checked before function call.  Proper radio button is checked based on value passed in.
    $('#cat' + cat).attr("checked", "checked");
    
    // valid values for subcategories are 1-7.  Value bound checked before function call. Proper radio button is checked based on value passed in.
    $('#sub' + sub).attr("checked", "checked");
    
    // valid values for difficulties are 1-4.  Value bound checked before function call. Proper radio button is checked based on value passed in.
    $('#dif' + dif).attr("checked", "checked");
    
    if(sch != 0)
    {
        $('#search').attr("value", sch);
    }
};


function switchImage (imgId) {
    var img = $('#' + imgId);
    //var imgSrc = img.css("background-image");
    var imgSrc = img.attr("src");
    //$('.productSelection h1').text(imgSrc);  // debug code
    
    var leftImg  = imgSrc.indexOf("_L");  // returns index of the substring or -1 if not found
    var rightImg = imgSrc.indexOf("_R");
    
    if(leftImg != -1)
    {
        var newImgSrc = imgSrc.replace("_L", "_R");
        //$('.productSelection h1').text("LEFT" + newImgSrc);  // debug code
        //img.css("background-image", newImgSrc);
        img.attr("src",newImgSrc);
    }
    else if(rightImg != -1)
    {
        var newImgSrc = imgSrc.replace("_R", "_L");
        //$('.productSelection h1').text("RIGHT" + newImgSrc);  // debug code
        //img.css("background-image", newImgSrc);
        img.attr("src",newImgSrc);
    }
};


/*  Internet Explorer 8 and lower ignores unknown tags and doesn't do any of their formating.  To fix this need to declare the unknown tags
 *  in javascript.  Thus IE will implement their formating.
 *  INPUT:  none
 *  RETURN: none
 */
function HTML5ieCompatability () {
    document.createElement("header");
    document.createElement("footer");
    document.createElement("section");
    document.createElement("article");
    document.createElement("nav");
    document.createElement("aside");
};




// Click a screenshot to view it larger; click anywhere or press Esc to close.
document.addEventListener('DOMContentLoaded',function(){
  var box=document.createElement('div');box.className='lightbox';box.setAttribute('role','dialog');
  box.innerHTML='<button class="lb-close" aria-label="Close">×</button><img alt=""><p class="lb-cap"></p>';
  document.body.appendChild(box);
  var img=box.querySelector('img'),cap=box.querySelector('.lb-cap');
  function close(){box.classList.remove('open');img.src='';}
  document.querySelectorAll('figure a').forEach(function(a){
    a.addEventListener('click',function(e){
      e.preventDefault();var i=a.querySelector('img');var fc=a.closest('figure').querySelector('figcaption');
      img.src=a.getAttribute('href');img.alt=i?i.alt:'';cap.textContent=fc?fc.textContent:'';box.classList.add('open');
    });
  });
  box.addEventListener('click',close);
  document.addEventListener('keydown',function(e){if(e.key==='Escape')close();});
});

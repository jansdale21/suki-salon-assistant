(function(){
  var box=document.createElement('div');box.className='lightbox';box.setAttribute('role','dialog');box.setAttribute('aria-modal','true');box.setAttribute('aria-label','Image preview');
  box.innerHTML='<button class="lb-close" aria-label="Close">×</button><img alt=""><p class="lb-cap"></p>';
  document.body.appendChild(box);
  var img=box.querySelector('img'),cap=box.querySelector('.lb-cap');
  function closeLightbox(){box.classList.remove('open');img.src='';}
  document.querySelectorAll('figure a').forEach(function(a){
    a.addEventListener('click',function(e){
      e.preventDefault();var i=a.querySelector('img');var fc=a.closest('figure').querySelector('figcaption');
      img.src=a.getAttribute('href');img.alt=i?i.alt:'';cap.textContent=fc?fc.textContent:'';box.classList.add('open');box.querySelector('.lb-close').focus();
    });
  });
  box.addEventListener('click',function(e){if(e.target===box||e.target===box.querySelector('.lb-close'))closeLightbox();});
  document.addEventListener('keydown',function(e){if(e.key==='Escape')closeLightbox();});

  var header=document.querySelector('header.site');
  var headerWrap=header&&header.querySelector('.wrap');
  var main=document.querySelector('main');
  var footer=document.querySelector('footer.site');
  var pageNav=headerWrap&&headerWrap.querySelector('nav.pages');
  if(!headerWrap||!main||!pageNav)return;

  var pages=Array.prototype.slice.call(pageNav.querySelectorAll('a'));
  var groups=[
    {label:'Overview',pages:['Summary']},
    {label:'System',pages:['AWS design','System card','Baseline']},
    {label:'Operations',pages:['Monitoring · Backup · Security','Automation · Incident']},
    {label:'Evaluation',pages:['Well-Architected','Results']},
    {label:'Project',pages:['Next steps','Declaration','Video']}
  ];
  var pageGroup='';
  groups.forEach(function(group){
    if(group.pages.some(function(label){return pages.some(function(link){return link.textContent.trim()===label&&link.classList.contains('on');});})){
      pageGroup=group.label;
    }
  });

  var layout=document.createElement('div');layout.className='docs-layout';
  var sidebar=document.createElement('aside');sidebar.className='docs-sidebar';sidebar.setAttribute('aria-label','Documentation navigation');
  var sidebarTop=document.createElement('div');sidebarTop.className='sidebar-top';
  var sidebarKicker=document.createElement('p');sidebarKicker.className='sidebar-kicker';sidebarKicker.textContent='SUKI · SAM10';
  sidebarTop.appendChild(sidebarKicker);
  sidebar.appendChild(sidebarTop);

  var groupedNav=document.createElement('nav');groupedNav.className='sidebar-nav';groupedNav.setAttribute('aria-label','Pages');
  groups.forEach(function(group){
    var section=document.createElement('section');section.className='nav-group';
    var label=document.createElement('h2');label.textContent=group.label;section.appendChild(label);
    var list=document.createElement('ul');
    group.pages.forEach(function(pageLabel){
      var source=pages.find(function(link){return link.textContent.trim()===pageLabel;});
      if(!source)return;
      var item=document.createElement('li');
      var link=source.cloneNode(true);link.classList.remove('on');
      if(source.classList.contains('on')){link.classList.add('on');link.setAttribute('aria-current','page');}
      item.appendChild(link);list.appendChild(item);
    });
    section.appendChild(list);groupedNav.appendChild(section);
  });
  sidebar.appendChild(groupedNav);

  var center=document.createElement('div');center.className='docs-reading';
  var breadcrumb=document.createElement('nav');breadcrumb.className='breadcrumbs';breadcrumb.setAttribute('aria-label','Breadcrumb');
  var breadcrumbList=document.createElement('ol');
  var homeItem=document.createElement('li');var homeLink=document.createElement('a');homeLink.href='index.html';homeLink.textContent='Suki docs';homeItem.appendChild(homeLink);breadcrumbList.appendChild(homeItem);
  if(pageGroup){var groupItem=document.createElement('li');groupItem.textContent=pageGroup;breadcrumbList.appendChild(groupItem);}
  var currentPage=pages.find(function(link){return link.classList.contains('on');});
  if(currentPage){var currentItem=document.createElement('li');currentItem.textContent=currentPage.textContent.trim();currentItem.setAttribute('aria-current','page');breadcrumbList.appendChild(currentItem);}
  breadcrumb.appendChild(breadcrumbList);
  center.appendChild(breadcrumb);
  main.id='main-content';main.classList.add('docs-main');
  center.appendChild(main);
  if(footer)center.appendChild(footer);

  var toc=document.createElement('aside');toc.className='docs-toc';toc.setAttribute('aria-label','Page contents');
  var tocTitle=document.createElement('p');tocTitle.className='toc-title';tocTitle.textContent='On this page';
  var tocNav=document.createElement('nav');tocNav.setAttribute('aria-label','On this page');
  var tocList=document.createElement('ol');tocList.className='toc-list';tocNav.appendChild(tocList);
  toc.appendChild(tocTitle);toc.appendChild(tocNav);

  var skip=document.createElement('a');skip.className='skip-link';skip.href='#main-content';skip.textContent='Skip to content';
  document.body.insertBefore(skip,document.body.firstChild);
  var sourceBrand=headerWrap.querySelector('.brand');
  var topbarBrand=document.createElement('a');topbarBrand.className='topbar-brand';topbarBrand.href=sourceBrand.getAttribute('href')||'index.html';
  topbarBrand.innerHTML='<img src="assets/logo.svg" alt=""><span>Suki <i>·</i> SAM10</span>';
  headerWrap.replaceChild(topbarBrand,sourceBrand);
  pageNav.remove();
  var mobileButton=document.createElement('button');mobileButton.className='sidebar-toggle';mobileButton.type='button';mobileButton.setAttribute('aria-label','Open documentation navigation');mobileButton.setAttribute('aria-expanded','false');mobileButton.innerHTML='<span></span><span></span><span></span>';
  headerWrap.insertBefore(mobileButton,headerWrap.firstChild);
  layout.appendChild(sidebar);layout.appendChild(center);layout.appendChild(toc);
  header.parentNode.insertBefore(layout,header.nextSibling);
  var backdrop=document.createElement('button');backdrop.className='layout-backdrop';backdrop.type='button';backdrop.setAttribute('aria-label','Close navigation');document.body.appendChild(backdrop);

  function closeSidebar(){document.body.classList.remove('sidebar-open');mobileButton.setAttribute('aria-expanded','false');mobileButton.setAttribute('aria-label','Open documentation navigation');}
  mobileButton.addEventListener('click',function(){
    var open=document.body.classList.toggle('sidebar-open');
    mobileButton.setAttribute('aria-expanded',String(open));mobileButton.setAttribute('aria-label',open?'Close documentation navigation':'Open documentation navigation');
  });
  backdrop.addEventListener('click',closeSidebar);
  groupedNav.addEventListener('click',function(e){if(e.target.closest('a'))closeSidebar();});

  function makeSlug(text){return text.toLowerCase().trim().replace(/[^\w\s-]/g,'').replace(/\s+/g,'-').replace(/-+/g,'-')||'section';}
  var headings=Array.prototype.slice.call(main.querySelectorAll('h2,h3'));
  var seen={};
  headings.forEach(function(heading){
    if(!heading.id){var base=makeSlug(heading.textContent);seen[base]=(seen[base]||0)+1;heading.id=seen[base]===1?base:base+'-'+seen[base];}
    var item=document.createElement('li');if(heading.tagName==='H3')item.className='toc-subitem';
    var link=document.createElement('a');link.href='#'+heading.id;link.textContent=heading.textContent.trim();item.appendChild(link);tocList.appendChild(item);
    link.addEventListener('click',closeSidebar);
  });
  if(!headings.length)toc.hidden=true;
  else if('IntersectionObserver'in window){
    var observer=new IntersectionObserver(function(entries){
      entries.forEach(function(entry){
        if(entry.isIntersecting){
          tocList.querySelectorAll('a').forEach(function(link){link.classList.toggle('active',link.hash==='#'+entry.target.id);});
        }
      });
    },{rootMargin:'-18% 0px -72% 0px'});
    headings.forEach(function(heading){observer.observe(heading);});
  }
  main.querySelectorAll('table').forEach(function(table){
    var wrapper=document.createElement('div');wrapper.className='table-scroll';wrapper.setAttribute('role','region');wrapper.setAttribute('aria-label','Scrollable table');wrapper.tabIndex=0;
    table.parentNode.insertBefore(wrapper,table);wrapper.appendChild(table);
  });
  main.querySelectorAll('figure img').forEach(function(image){
    if(image.getAttribute('src').indexOf('evidence/')!==-1)image.closest('figure').classList.add('evidence-figure');
  });

  document.addEventListener('keydown',function(e){if(e.key==='Escape')closeSidebar();});
  document.body.classList.add('docs-ready');
})();

// Apply the saved theme before paint. This preference never changes report data.
(function(){let theme='dark';try{const saved=localStorage.getItem('sanam_theme');if(['dark','light'].includes(saved))theme=saved;}catch{}document.documentElement.dataset.theme=theme;})();


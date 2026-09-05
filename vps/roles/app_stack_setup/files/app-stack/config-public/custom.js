(function() {
    'use strict';

    function init() {
        injectFooter();
    }

    function injectFooter() {
        if (document.getElementById('merox-footer')) return;
        const footer = document.createElement('div');
        footer.id = 'merox-footer';
        footer.innerHTML =
            '<a href="https://merox.dev" target="_blank" rel="noopener noreferrer">merox.dev</a>' +
            '<span class="footer-sep">·</span>' +
            '<a href="https://osintframework.com" target="_blank" rel="noopener noreferrer">osintframework.com</a>';
        document.body.appendChild(footer);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    setTimeout(init, 500);
})();


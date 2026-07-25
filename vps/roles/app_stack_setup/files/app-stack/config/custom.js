(function() {
    'use strict';

    function init() {
        injectFooter();
        injectMobileButton();
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

    function injectMobileButton() {
        if (document.getElementById('merox-home-button')) return;
        const button = document.createElement('a');
        button.id = 'merox-home-button';
        button.href = 'https://merox.dev';
        button.target = '_blank';
        button.rel = 'noopener noreferrer';
        button.setAttribute('aria-label', 'Go to merox.dev');
        button.innerHTML =
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"></path>' +
            '<polyline points="9 22 9 12 15 12 15 22"></polyline>' +
            '</svg>' +
            '<span>merox.dev</span>';
        document.body.appendChild(button);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    setTimeout(init, 500);
})();


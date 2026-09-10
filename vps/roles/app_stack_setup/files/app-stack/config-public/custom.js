/*
 * inside.merox.dev — the masthead and footer Homepage has no setting for.
 *
 * The text below is copied from the homelab-tour post's own lede and spec
 * sheet, deliberately: this page is that post's table of contents, and two
 * hand-written summaries of one stack drift apart. If the post changes,
 * change this with it.
 */
(function () {
    'use strict';

    var SPECS = [
        ['3 × Proxmox', 'hosts'],
        ['Talos + Flux', 'kubernetes'],
        ['~6 TB', 'zfs pools'],
        ['~165 W', 'draw'],
        ['0', 'inbound ports'],
        ['3', 'backup copies']
    ];

    function intro() {
        var wrapper = document.getElementById('page-wrapper');
        if (!wrapper || document.getElementById('merox-intro')) return;

        var el = document.createElement('header');
        el.id = 'merox-intro';
        el.innerHTML =
            '<div class="intro-eyebrow">inside.merox.dev</div>' +
            '<h1 class="intro-title">The homelab I run after hours</h1>' +
            '<p class="intro-lede">Three Proxmox hosts, one Talos node each — mini PC (GPU), ' +
            'R730xd (disks), OptiPlex (etcd vote). Oracle Cloud VPS at the edge, one backup ' +
            'chain underneath all three.</p>' +
            '<dl class="intro-specs">' +
            SPECS.map(function (s) {
                return '<div><dt>' + s[1] + '</dt><dd>' + s[0] + '</dd></div>';
            }).join('') +
            '</dl>' +
            '<a class="intro-cta" href="https://merox.dev/blog/homelab-tour" ' +
            'target="_blank" rel="noopener noreferrer">Read the full tour</a>';

        wrapper.insertBefore(el, wrapper.firstChild);
    }

    function footer() {
        if (document.getElementById('merox-footer')) return;
        var el = document.createElement('div');
        el.id = 'merox-footer';
        el.innerHTML =
            '<a href="https://merox.dev" target="_blank" rel="noopener noreferrer">merox.dev</a>' +
            '<span class="footer-sep">·</span>' +
            '<a href="https://github.com/meroxdotdev/infrastructure" target="_blank" rel="noopener noreferrer">the repo</a>' +
            '<span class="footer-sep">·</span>' +
            '<a href="https://osintframework.com" target="_blank" rel="noopener noreferrer">osintframework.com</a>';
        document.body.appendChild(el);
    }

    function init() {
        intro();
        footer();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    // The masthead sits inside a container React owns, so a re-render can drop
    // it. Both injectors are guarded by id, so re-running is free.
    new MutationObserver(init).observe(document.body, { childList: true, subtree: true });
})();

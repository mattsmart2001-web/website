/* GTEC shared footer — small attribution strip injected at the bottom
   of every public page. Pages just include this script; no per-page
   markup. Stays subtle so it ties the site together without competing
   with the corner SparksTheory logo or the GTEC nav mark. */
(function () {
    'use strict';

    if (document.getElementById('gtec-footer')) return;

    if (!document.getElementById('gtec-footer-style')) {
        const style = document.createElement('style');
        style.id = 'gtec-footer-style';
        style.textContent = `
            #gtec-footer {
                position: relative;
                margin-top: 4rem;
                padding: 1.75rem 1.5rem 2rem;
                border-top: 1px solid rgba(255, 255, 255, 0.06);
                text-align: center;
                font-family: 'Orbitron', sans-serif;
                font-size: 0.62rem;
                font-weight: 600;
                letter-spacing: 0.28em;
                text-transform: uppercase;
                color: rgba(148, 163, 184, 0.65);
                z-index: 1;
            }
            #gtec-footer a {
                color: inherit;
                text-decoration: none;
                transition: color 0.15s ease;
            }
            #gtec-footer a:hover { color: #ffd166; }
            #gtec-footer .gtec-footer-dot { color: rgba(255, 209, 102, 0.55); margin: 0 0.4em; }
            #gtec-footer .gtec-footer-partner {
                display: inline-flex;
                align-items: center;
                gap: 0.45em;
                margin-bottom: 0.95rem;
                padding: 0.55rem 1.1rem;
                border-radius: 999px;
                border: 1px solid rgba(255, 209, 102, 0.4);
                background: rgba(255, 209, 102, 0.08);
                color: #ffd166;
                font-size: 0.6rem;
                letter-spacing: 0.2em;
                transition: background 0.15s ease, border-color 0.15s ease;
            }
            #gtec-footer .gtec-footer-partner:hover {
                background: rgba(255, 209, 102, 0.16);
                border-color: rgba(255, 209, 102, 0.7);
                color: #ffd166;
            }
        `;
        document.head.appendChild(style);
    }

    const year = new Date().getFullYear();
    const footer = document.createElement('footer');
    footer.id = 'gtec-footer';
    footer.innerHTML = `
        <a class="gtec-footer-partner" href="/endurance/partners/" title="Partner with GTEC">🤝 Partner with GTEC</a>
        <div>
            GTEC
            <span class="gtec-footer-dot">·</span>
            A <a href="/" title="SparksTheory">SparksTheory</a> Championship
            <span class="gtec-footer-dot">·</span>
            © ${year}
        </div>
    `;
    document.body.appendChild(footer);
})();

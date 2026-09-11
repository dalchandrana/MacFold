/**
 * Mac Fold — Apple Developer Documentation Hub Scripts
 * Handles sidebar active states, 1-click code copying, and client-side topic search.
 */

(function () {
  'use strict';

  // 1-Click Code Block Copying
  document.querySelectorAll('.code-copy-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const codeWrapper = btn.closest('.code-wrapper');
      const code = codeWrapper ? codeWrapper.querySelector('pre code') : null;
      if (!code) return;

      try {
        await navigator.clipboard.writeText(code.innerText.trim());
        const originalText = btn.innerHTML;
        btn.innerHTML = `
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--apple-green)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="20 6 9 17 4 12"></polyline>
          </svg>
          <span style="color: var(--apple-green)">Copied!</span>
        `;
        setTimeout(() => {
          btn.innerHTML = originalText;
        }, 2000);
      } catch (err) {
        console.error('Failed to copy code snippet: ', err);
      }
    });
  });

  // Client-Side Docs Search
  const searchInput = document.getElementById('docs-search');
  if (searchInput) {
    searchInput.addEventListener('input', (e) => {
      const query = e.target.value.toLowerCase().trim();
      const navLinks = document.querySelectorAll('.docs-nav-link');
      const navGroups = document.querySelectorAll('.docs-nav-group');

      navLinks.forEach((link) => {
        const text = link.textContent.toLowerCase();
        const matches = text.includes(query);
        link.parentElement.style.display = matches ? 'block' : 'none';
      });

      // Hide empty groups
      navGroups.forEach((group) => {
        const visibleItems = group.querySelectorAll('li:not([style*="display: none"])');
        group.style.display = visibleItems.length > 0 ? 'block' : 'none';
      });
    });
  }

  // Active Link Highlighting with IntersectionObserver
  const headings = document.querySelectorAll('.docs-article h2[id], .docs-article h3[id]');
  const navLinks = document.querySelectorAll('.docs-nav-link');

  if (headings.length > 0 && navLinks.length > 0) {
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            const id = entry.target.getAttribute('id');
            navLinks.forEach((link) => {
              const href = link.getAttribute('href');
              if (href === `#${id}`) {
                navLinks.forEach((l) => l.classList.remove('active'));
                link.classList.add('active');
              }
            });
          }
        });
      },
      { rootMargin: '-80px 0px -70% 0px', threshold: 0.1 }
    );

    headings.forEach((heading) => observer.observe(heading));
  }
})();

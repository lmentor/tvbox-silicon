// iOS 16.2 WebKit predates media-query range syntax. Restore the document's
// own responsive rules; modern engines retain the authored styles unchanged.
(() => {
  if (window.top !== window || matchMedia('(width >= 0px)').matches) return;
  const rewrite = css => css.replace(/\/\*[\s\S]*?\*\/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(@media\b)([^{};]*)\{/gi,
    (rule, media, condition) => !media ? rule : media + condition.replace(
      /\(\s*(width|height)\s*(<=|>=)\s*(\d*\.?\d+(?:px|em|rem|vw|vh|vmin|vmax))\s*\)/gi,
      (_, axis, operator, value) => '(' + (operator === '<=' ? 'max-' : 'min-') + axis + ':' + value + ')') + '{');
  const update = style => {
    const before = style.textContent;
    const after = rewrite(before);
    if (after !== before) style.textContent = after;
  };
  // At document start the head may not exist. Observe the document itself,
  // including style text replaced by a page's client-side rendering code.
  new MutationObserver(records => {
    const changed = new Set();
    for (const record of records) {
      const target = record.target.nodeType === 3 ? record.target.parentElement : record.target;
      if (target?.tagName === 'STYLE') changed.add(target);
      for (const node of record.addedNodes || []) {
        if (node.nodeType !== 1) continue;
        if (node.tagName === 'STYLE') changed.add(node);
        else node.querySelectorAll('style').forEach(style => changed.add(style));
      }
    }
    changed.forEach(update);
  }).observe(document, { subtree: true, childList: true, characterData: true });
  document.querySelectorAll('style').forEach(update);
})();

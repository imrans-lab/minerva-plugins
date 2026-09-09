// Building blocks for every view, and the reason the panel has no innerHTML.
//
// A council carries text nobody in this codebase wrote: a member's answer comes
// from a model, a source excerpt comes from whatever the user captured, and a
// council definition can arrive by import from another project. The prototype
// escaped that text into an HTML string; escaping is a rule that has to be
// remembered at every concatenation, and forgetting once is a script tag in a
// snapshot away from running.
//
// So the production page never builds markup. `el()` creates elements and every
// piece of record text goes in through `textContent`, which cannot parse. There
// is no path from a snapshot value to the HTML parser, so there is nothing for a
// review to check for and nothing for a payload to slip past.

(function (global) {
  'use strict';

  // el(tag, props, children)
  //
  // props keys:
  //   class      → className
  //   text       → textContent (the only way record text enters the document)
  //   html       → refused; the property exists so a mistake fails loudly
  //   data       → an object of data-* attributes
  //   aria       → an object of aria-* attributes
  //   anything else → an attribute, except `on*` which become listeners
  //
  // A child may be a node, a string (becomes a text node), or null/false/
  // undefined, which is skipped so a view can write `cond && el(...)` inline.
  function el(tag, props, children) {
    var node = document.createElement(tag);
    var key;
    if (props) {
      for (key in props) {
        if (!Object.prototype.hasOwnProperty.call(props, key)) { continue; }
        apply(node, key, props[key]);
      }
    }
    append(node, children);
    return node;
  }

  function apply(node, key, value) {
    if (value === undefined || value === null || value === false) { return; }
    if (key === 'html') {
      throw new Error('the Council panel builds nodes, never markup');
    }
    if (key === 'class') { node.className = String(value); return; }
    if (key === 'text') { node.textContent = String(value); return; }
    if (key === 'data' || key === 'aria') {
      var prefix = key === 'data' ? 'data-' : 'aria-';
      for (var name in value) {
        if (!Object.prototype.hasOwnProperty.call(value, name)) { continue; }
        if (value[name] === undefined || value[name] === null || value[name] === false) { continue; }
        node.setAttribute(prefix + name, String(value[name]));
      }
      return;
    }
    if (key.indexOf('on') === 0 && typeof value === 'function') {
      node.addEventListener(key.slice(2).toLowerCase(), value);
      return;
    }
    node.setAttribute(key, value === true ? '' : String(value));
  }

  // 0 and '' are skipped along with the falsy trio, and that is not tidiness:
  // views are written as `list.length && el(...)`, and an empty list makes that
  // expression the NUMBER 0, which would otherwise be appended as the character
  // "0" at the end of the block. Text always arrives through `text:`, so a bare
  // 0 or empty string in a child list is never something a view meant to show.
  function append(node, children) {
    if (children === undefined || children === null || children === false
        || children === 0 || children === '') { return; }
    if (Array.isArray(children)) {
      for (var i = 0; i < children.length; i++) { append(node, children[i]); }
      return;
    }
    node.appendChild(typeof children === 'object' && children.nodeType
      ? children
      : document.createTextNode(String(children)));
  }

  // A detached parent for a list of siblings, so a view can return several
  // top-level blocks without inventing a wrapper element the CSS then has to
  // know about.
  function frag(children) {
    var f = document.createDocumentFragment();
    append(f, children);
    return f;
  }

  function clear(node) {
    while (node.firstChild) { node.removeChild(node.firstChild); }
    return node;
  }

  function replace(node, children) {
    clear(node);
    append(node, children);
    return node;
  }

  global.CouncilDom = { el: el, frag: frag, clear: clear, replace: replace };
})(window);

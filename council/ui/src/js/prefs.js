// Council's own text size.
//
// WHY THIS IS NOT THE HOST'S SCALE. Minerva's UI scale resizes the whole
// application and, for this panel, changes the density the page is rendered at
// (council_panel.gd `_apply_oversampling`). It does not decide how large
// Council's prose is, and should not: this surface is read at an editor pane's
// width while the rest of Minerva is chrome, so the size that suits one does not
// suit the other, and the host's scale shortcuts do not reach inside the
// embedded browser at all. The size is therefore Council's — stored by the
// wrapper beside the panel rather than in the document, because a preference is
// not project data and carrying it in the record would put one reader's choice
// into another's project — and applied as one CSS variable that scales every
// type size at once.
//
// The steps are multiplicative and coarse on purpose: a reader picks a size once
// and then reads. Ctrl + / Ctrl - / Ctrl 0 drive the same steps.
//
// WHICH STEPS ARE REAL. The wrapper decides what it will store, and says so in
// `wrapper.describe`. This file's list is the page's own, and `adopt()` keeps
// only the sizes both sides know: a step the wrapper would refuse is a control
// that does nothing, and a size the wrapper accepts but the page has no step for
// is a value nobody can reach. A wrapper that names none — an older build — is
// taken at the page's defaults.

(function (global) {
  'use strict';

  var STEPS = [0.85, 1.0, 1.12, 1.28, 1.45, 1.7];
  var DEFAULT = 1.12;

  function TextSize(bridge) {
    this.bridge = bridge;
    this.steps = STEPS.slice();
    this.scale = DEFAULT;
    this.onChange = function () {};
  }

  TextSize.prototype.adopt = function (offered) {
    if (!Array.isArray(offered) || !offered.length) { return; }
    var shared = STEPS.filter(function (step) {
      return offered.some(function (value) { return Number(value) === step; });
    });
    // An empty intersection means the two builds share no size at all. The
    // wrapper's list wins there, because it is the one that decides what can be
    // stored; the sizes are simply coarser or finer than this page expected.
    this.steps = shared.length ? shared : offered.map(Number);
    this.scale = this.nearest(this.scale);
  };

  TextSize.prototype.nearest = function (value) {
    var scale = Number(value);
    var best = this.steps[0];
    if (!isFinite(scale) || scale <= 0) { scale = DEFAULT; }
    for (var i = 0; i < this.steps.length; i++) {
      if (Math.abs(this.steps[i] - scale) < Math.abs(best - scale)) { best = this.steps[i]; }
    }
    return best;
  };

  TextSize.prototype.apply = function () {
    document.documentElement.style.setProperty('--text-scale', String(this.scale));
    this.onChange(this.scale);
  };

  // Read the stored preference. A wrapper that does not answer — an older build,
  // or a panel that has not mounted — leaves the default in place rather than
  // failing: text size is never a reason for the panel not to open.
  TextSize.prototype.load = function () {
    var self = this;
    return this.bridge.send('wrapper.get_preferences', {}).then(function (reply) {
      if (reply && reply.ok && reply.payload && reply.payload.text_scale !== undefined) {
        self.scale = self.nearest(reply.payload.text_scale);
      }
      self.apply();
      return self.scale;
    });
  };

  TextSize.prototype.index = function () { return this.steps.indexOf(this.nearest(this.scale)); };
  TextSize.prototype.canGrow = function () { return this.index() < this.steps.length - 1; };
  TextSize.prototype.canShrink = function () { return this.index() > 0; };

  TextSize.prototype.set = function (scale) {
    var wanted = this.nearest(scale);
    if (wanted === this.scale) { return; }
    this.scale = wanted;
    this.apply();
    // Fire and forget: the size is already on screen, and a preference that
    // failed to store is a smaller loss than a panel that waits to redraw.
    this.bridge.send('wrapper.set_preference', { text_scale: wanted });
  };

  TextSize.prototype.step = function (direction) {
    var at = this.index();
    this.set(this.steps[Math.max(0, Math.min(this.steps.length - 1, at + direction))]);
  };

  TextSize.prototype.reset = function () { this.set(DEFAULT); };

  // What the foot rail shows. Percentages of the default, so "100%" is the size
  // Council opens at rather than the browser's.
  TextSize.prototype.label = function () {
    return Math.round((this.scale / DEFAULT) * 100) + '%';
  };

  global.CouncilPrefs = { TextSize: TextSize, STEPS: STEPS, DEFAULT: DEFAULT };
})(window);

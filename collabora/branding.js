// Collabora's own branding.js, VENDORED VERBATIM, with a Fortress viewport-sync bridge
// appended at the bottom.
//
// WHY THIS FILE EXISTS AT ALL
//
// Collabora's postMessage API cannot sync scroll or zoom. Its complete set of outgoing
// messages contains nothing for either (Doc_PartChanged reports a sheet change and that is
// all), and nothing inbound sets zoom: .uno:ZoomPlus is dropped because zoom is client-side
// state the server knows nothing about, .uno:Zoom opens an interactive dialog, and
// Action_FollowUser was measured doing nothing across three configurations. So presenter
// viewport sync for spreadsheets is impossible from outside the iframe.
//
// It is entirely possible from INSIDE it. cool.html loads this file as a plain <script>, so
// code here runs in Collabora's own page with access to its internals -- which do expose
// everything needed. This is the only script tag in that page we can own without patching
// Collabora or building a custom image: there is no config option for injecting custom JS
// (coolwsd.xml has nothing of the kind), and the alternative -- rewriting cool.html at the
// nginx proxy -- would work in staging and silently not in local dev, where there is no nginx.
//
// MAINTENANCE CONTRACT -- read before upgrading the Collabora image.
//
// 1. Everything above the Fortress section is Collabora's file, copied byte for byte from
//    CODE 26.04.3-1. Mounting this over theirs means their branding is now pinned at that
//    version. On upgrade, re-copy their branding.js from the new image and re-append the
//    Fortress section. Their code is left intact rather than edited in place, so the two
//    stay separable and the next upgrade is a re-copy rather than a merge.
// 2. The toolbar logo their setLogo() wires up is hidden by the Fortress section, via CSS
//    rather than by editing their function. That was a deliberate call (see hideVendorLogo),
//    not a side effect of how we hooked in -- and it is the reason an upgrade must re-check
//    the `#document-header` selector, which is the one piece of their DOM we now depend on.
// 3. The bridge uses UNDOCUMENTED internals (app.map, activeLayout.viewedRectangle,
//    _docLayer._docPixelSize). These can change in any release. Every access is guarded and
//    the bridge degrades to doing nothing rather than throwing, so a broken upgrade costs
//    viewport sync, not the viewer.
//
/* (C) Collabora Productivity 2026, All Rights Reserved, (version 26.04.3-1) */

var brandProductName = 'Collabora Online Development Edition (CODE)';
var brandProductURL = 'https://www.collaboraonline.com/code/';
var brandProductFAQURL = 'https://www.collaboraonline.com/code/#code-scalability';
var menuItems;
window.onload = function() {
	// wait until the menu (and particularly the document-header) actually exists
	function setLogo() {
		var logoHeader = document.getElementById('document-header');
		var logo = logoHeader && document.querySelector('#document-header > a');
		if (!logo) {
			// the logo does not exist in the menu yet, re-try in 250ms
			setTimeout(setLogo, 250);
		} else {
			logo.setAttribute('data-cooltip', brandProductName);
			logo.setAttribute('href', brandProductURL);
			logo.addEventListener('click', function(e) {
				// Route through window.open so the desktop apps reopen the link
				// in the system browser via the HYPERLINK bridge instead of a
				// new embedded webview window.
				e.preventDefault();
				window.open(brandProductURL, '_blank');
			});

			menuItems = document.querySelectorAll('#main-menu > li > a');
		}
	}
	function setAboutImg() {
		var lk = document.getElementById('lokit-version');
		var aboutDialog = document.getElementById('about-dialog-info');
		if (!lk || !aboutDialog) {
			setTimeout(setAboutImg, 250);
		} else {
			var div = document.createElement('div');
			div.style.marginInlineEnd = 'auto';
			div.id = 'lokit-extra';

			let span = document.createElement('span');
			span.setAttribute('dir', 'ltr');
			span.textContent = 'built on\u00A0';

			let anchor = document.createElement('a');
			anchor.href = 'https://col.la/lot';
			anchor.setAttribute('target', '_blank');
			anchor.textContent = 'a great technology base';

			div.appendChild(span);
			div.appendChild(anchor);
			lk.parentNode.parentNode.insertBefore(div, lk.parentNode);
		}
	}

	function addIntegratorSidebar() {
		var logoHeader = document.getElementById('document-header');
		if (!logoHeader) {
			// the logo does not exist in the menu yet, re-try in 250ms
			setTimeout(addIntegratorSidebar, 250);
		}
   }


	setLogo();
	setAboutImg();
	addIntegratorSidebar();
}

/*a::first-letter"*/
document.onkeyup = function(e) {
	if (e.altKey && e.shiftKey) {
		menuItems.forEach(function(menuItem) {
		  menuItem.style.setProperty('text-decoration', 'underline', 'important');
		});
	}
};

/* ------------------------------------------------------------------------- *
 * Fortress additions. Everything above this line is Collabora's.
 * ------------------------------------------------------------------------- */

/*
 * Hides the product logo in the top-left of the toolbar.
 *
 * The element is `#document-header > a.document-logo`, which Collabora's own setLogo() above
 * turns into a link out to collaboraonline.com. In a deposition the exhibit viewer is the
 * product, and a vendor link sitting in the toolbar of a legal exhibit is both off-brand and
 * a way out of the room mid-record.
 *
 * Collabora already ships a rule for this, but it is scoped
 * `.main-nav.hasnotebookbar.readonly > #main-menu #document-header` -- i.e. only in the tabbed
 * notebookbar UI. collabora.yml pins the server to compact mode (see its comment on
 * user_interface.mode), so that selector never matches here and the logo stays visible. Hence
 * an unconditional rule of our own.
 *
 * Done as CSS rather than by removing the node: the toolbar is re-rendered on context changes
 * (the same behaviour that defeated Hide_NotebookTab -- see office-viewer/collabora.ts), and a
 * removed element would simply come back. A stylesheet survives re-renders. `!important` is
 * required because bundle.css later sets `#document-header{...;display:flex}` unconditionally.
 *
 * Note this is deliberately narrower than hiding vendor attribution generally: the About
 * dialog and its "built on a great technology base" credit are untouched.
 */
(function hideVendorLogo() {
    'use strict';

    var style = document.createElement('style');

    style.textContent = '#document-header { display: none !important; }';

    // documentElement rather than head: this script is a plain <script> in cool.html and runs
    // during parse, so <head> is present, but appending to the root works regardless of where
    // Collabora moves the tag on a future upgrade.
    (document.head || document.documentElement).appendChild(style);
})();

/* ------------------------------------------------------------------------- *
 * Fortress viewport-sync bridge.
 * ------------------------------------------------------------------------- */
(function () {
    'use strict';

    var PREFIX = 'Fortress_';
    // Scroll fires continuously; this is the coalescing window before a position is sent.
    var THROTTLE_MS = 120;

    var applying = false;
    var lastKey = '';

    function map() {
        return window.app && window.app.map;
    }

    function layout() {
        return window.app && window.app.activeDocument && window.app.activeDocument.activeLayout;
    }

    // Total document size in the SAME pixel units viewedRectangle/scrollTo use.
    function docSize() {
        var m = map();
        return m && m._docLayer && m._docLayer._docPixelSize;
    }

    function targetOrigin() {
        var m = map();
        // Prefer the origin the WOPI host declared; only that page should see viewport data.
        return (m && m.wopi && m.wopi.PostMessageOrigin) || '*';
    }

    function post(id, values) {
        try {
            window.parent.postMessage(
                JSON.stringify({ MessageId: PREFIX + id, Values: values || {} }),
                targetOrigin());
        } catch (e) { /* parent gone */ }
    }

    /**
     * Current viewport as ZOOM plus a 0-1 fraction of the document on each axis.
     *
     * Fractions rather than raw pixels on purpose: pixel offsets are meaningless across
     * clients, because they depend on the viewer's own zoom level, panel width and device
     * pixel ratio. A fraction means the same place in the document on every screen, and stays
     * correct even if a follower's zoom has not been applied yet.
     */
    function read() {
        var m = map(), l = layout(), d = docSize();

        if (!m || !l || !d || !d.x || !d.y || !l.viewedRectangle) {
            return null;
        }

        var r = l.viewedRectangle;

        if (typeof r.pX1 !== 'number' || typeof r.pY1 !== 'number') {
            return null;
        }

        return {
            zoom: m.getZoom(),
            fx: Math.min(1, Math.max(0, r.pX1 / d.x)),
            fy: Math.min(1, Math.max(0, r.pY1 / d.y))
        };
    }

    function emit() {
        if (applying) {
            return;
        }

        var v = read();

        if (!v) {
            return;
        }

        // Cheap dedupe -- 'move' fires far more often than the view meaningfully changes.
        var key = v.zoom + ':' + v.fx.toFixed(4) + ':' + v.fy.toFixed(4);

        if (key === lastKey) {
            return;
        }

        lastKey = key;
        post('ViewChanged', v);
    }

    /**
     * Scrolls to a fractional position, then verifies and retries.
     *
     * The retry is not defensive padding. Changing zoom resizes the document ASYNCHRONOUSLY --
     * the tiles re-render and _docPixelSize grows or shrinks afterwards -- so a scroll issued
     * in the same turn as a zoom change resolves its fraction against the OLD document height
     * and gets clamped. Measured: applying zoom 16 with fy 0.45 to a Writer document landed at
     * fy 0.032, pinned near the top, while the identical scroll with no zoom change landed at
     * 0.44993. Without this the follower silently sits in the wrong place whenever the
     * presenter zooms and scrolls together, and stays there if the presenter then stops moving.
     */
    function applyScroll(v, attempt, done) {
        var l = layout(), d = docSize();

        if (!l || !d || !d.x || !d.y) {
            done();

            return;
        }

        l.scrollTo(v.fx * d.x, v.fy * d.y);

        if (attempt >= 4) {
            done();

            return;
        }

        setTimeout(function () {
            var cur = read();

            if (cur && (Math.abs(cur.fx - v.fx) > 0.005 || Math.abs(cur.fy - v.fy) > 0.005)) {
                applyScroll(v, attempt + 1, done);
            } else {
                done();
            }
        }, 150);
    }

    function apply(v) {
        var m = map(), l = layout();

        if (!m || !l || !v) {
            return;
        }

        applying = true;

        try {
            if (typeof v.zoom === 'number' && v.zoom !== m.getZoom()) {
                // ONE argument. This is not a style choice and must not be "tidied" into
                // passing options explicitly.
                //
                // setZoom(n, e) delegates to setDesktopCalcViewOnZoom(n, e) for spreadsheets on
                // desktop, and that path derives the zoom centre from the second argument.
                // Calling setZoom(zoom, null, true) -- which looks harmless and mirrors what
                // Collabora's own zoom action passes to zoomIn -- silently updates the internal
                // zoom value WITHOUT re-rendering: getZoom() reports the new level while the
                // document stays drawn at the old scale. Measured repeatedly before the cause
                // was found. Omitting the argument entirely renders correctly.
                //
                // map.zoomIn()/zoomOut() and app.dispatcher.dispatch('zoomin') were both also
                // measured as complete no-ops from here, despite being exactly what the
                // status-bar buttons call. setZoom with a single argument is the only route
                // that works.
                //
                // Note the units: this is Collabora's integer zoom LEVEL, not a percentage --
                // level 10 renders at 100% and level 15 at 235%. Syncing the level keeps every
                // client identical without needing to model that curve.
                m.setZoom(v.zoom);
            }
        } catch (e) { /* internals moved; degrade to no sync rather than throwing */ }

        applyScroll(v, 0, function () {
            // Re-baseline only once the scroll has actually settled, so the next genuine local
            // move is not swallowed by the dedupe and the retries never echo back out.
            var cur = read();

            lastKey = cur ? cur.zoom + ':' + cur.fx.toFixed(4) + ':' + cur.fy.toFixed(4) : '';
            applying = false;
        });
    }

    window.addEventListener('message', function (e) {
        var msg;

        try {
            msg = JSON.parse(e.data);
        } catch (_) {
            return;
        }

        if (msg && msg.MessageId === PREFIX + 'ApplyView') {
            apply(msg.Values);
        }

        // Diagnostic channel. Kept deliberately rather than removed after the initial build:
        // this bridge reads undocumented internals that move between Collabora releases, and
        // when viewport sync silently stops working after an upgrade this is what says which
        // property went missing, without needing a debugger attached to a live deposition.
        if (msg && msg.MessageId === PREFIX + 'Probe') {
            var m = map(), l = layout(), d = docSize();
            var r = l && l.viewedRectangle;

            post('ProbeResult', {
                hasMap: !!m,
                hasLayout: !!l,
                hasDocSize: !!d,
                docSize: d ? { x: d.x, y: d.y } : null,
                zoom: m && typeof m.getZoom === 'function' ? m.getZoom() : null,
                rect: r ? { pX1: r.pX1, pY1: r.pY1, pX2: r.pX2, pY2: r.pY2, x1: r.x1, y1: r.y1 } : null,
                read: read()
            });
        }
    });

    // POLLED rather than event-driven, and that is not laziness.
    //
    // The obvious hooks -- map.on('move'/'moveend'/'zoomend') -- were tried first and measured
    // never firing: zooming the document to 200% through Collabora's own status-bar button
    // produced no event at all. Those Leaflet events are vestigial here, because Collabora
    // reimplemented scrolling and zooming on its own canvas sections rather than Leaflet's
    // panning (note viewedRectangle's setter calls app.sectionContainer.onNewDocumentTopLeft
    // directly). Guessing at the correct internal event would also be far more fragile across
    // upgrades than reading two numbers on a timer.
    //
    // Cost is negligible: read() is a couple of property lookups, and emit() dedupes so
    // nothing is sent while the view is still.
    (function attach() {
        var m = map();

        if (!m) {
            setTimeout(attach, 300);

            return;
        }

        setInterval(emit, THROTTLE_MS);
        post('BridgeReady', read() || {});
    })();
})();

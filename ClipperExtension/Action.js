// Safari JS preprocessing: capture the live (possibly authenticated) DOM and
// hand it to the extension. iOS silently drops oversized item-provider
// payloads — the historical cause of "title-only" clips on heavy pages — so
// the capture strips non-content weight (scripts, styles) and falls back to a
// reduced article-centric document when the page is still too large.
//
// JSON-LD <script type="application/ld+json"> blocks are preserved: the
// extension's fast path extracts articleBody from them (NYT, Wired).

var Action = function() {};

Action.prototype = {

    // Serialized payloads above this trigger the reduced-document fallback.
    TRIM_THRESHOLD: 2 * 1024 * 1024,
    // Hard cap; item providers reliably deliver payloads of this size.
    MAX_CHARS: 4 * 1024 * 1024,

    run: function(args) {
        var self = this;
        var complete = function() {
            var html = "";
            try {
                html = self.captureHTML();
            } catch (e) {
                try { html = document.documentElement.outerHTML; } catch (e2) {}
            }
            args.completionFunction({
                "title": document.title,
                "URL": window.location.href,
                "html": html,
                "capturedVia": "actionjs-v2",
                "htmlLength": html.length
            });
        };
        // The user is looking at a rendered page, so usually capture
        // immediately; give a still-loading document one beat to settle.
        if (document.readyState === "loading") {
            setTimeout(complete, 500);
        } else {
            complete();
        }
    },

    captureHTML: function() {
        var clone = document.documentElement.cloneNode(true);
        this.strip(clone);
        var html = clone.outerHTML;
        if (html.length > this.TRIM_THRESHOLD) {
            var reduced = this.reducedDocument();
            if (reduced && reduced.length > 0) {
                html = reduced;
            }
        }
        if (html.length > this.MAX_CHARS) {
            html = html.substring(0, this.MAX_CHARS);
        }
        return html;
    },

    // Remove non-content weight from a cloned subtree. Never touches the
    // live page. Keeps JSON-LD scripts — the extension's fast path needs them.
    strip: function(root) {
        var selector = 'script:not([type="application/ld+json"]), style, link[rel="stylesheet"], noscript';
        var nodes = root.querySelectorAll(selector);
        for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            if (node.parentNode) {
                node.parentNode.removeChild(node);
            }
        }
    },

    // Article-centric fallback for very large pages: head metadata + all
    // JSON-LD blocks + the most article-like subtree.
    reducedDocument: function() {
        var head = "<title>" + this.escapeHTML(document.title || "") + "</title>";
        var metas = document.querySelectorAll('meta[property], meta[name], link[rel="canonical"]');
        for (var i = 0; i < metas.length; i++) {
            head += metas[i].outerHTML;
        }

        var ldBlocks = "";
        var lds = document.querySelectorAll('script[type="application/ld+json"]');
        for (var j = 0; j < lds.length; j++) {
            ldBlocks += lds[j].outerHTML;
        }

        var article = document.querySelector("article")
            || document.querySelector("main")
            || document.querySelector('[role="main"]')
            || document.body;
        if (!article) {
            return null;
        }
        var clone = article.cloneNode(true);
        this.strip(clone);

        return "<html><head>" + head + "</head><body>" + ldBlocks + clone.outerHTML + "</body></html>";
    },

    escapeHTML: function(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
};

var ExtensionPreprocessingJS = new Action();

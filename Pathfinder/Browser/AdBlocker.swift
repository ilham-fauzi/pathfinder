import Foundation

/// Built-in rules in WebKit's content-blocker format: third-party ad/tracker requests are blocked,
/// and common ad containers are hidden. Not a full filter list (EasyList), so some ads will remain.
enum AdBlocker {
    static let identifier = "ydl-adblock-v3"

    /// Third-party hosts that only serve ads or tracking.
    static let blockedHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "google-analytics.com", "googletagservices.com", "2mdn.net", "adnxs.com", "adsrvr.org",
        "taboola.com", "outbrain.com", "criteo.com", "criteo.net", "pubmatic.com", "rubiconproject.com",
        "openx.net", "amazon-adsystem.com", "scorecardresearch.com", "moatads.com", "advertising.com",
        "casalemedia.com", "33across.com", "teads.tv", "zedo.com", "yieldmo.com", "lijit.com",
        "sharethrough.com", "media.net", "adform.net", "bidswitch.net", "smartadserver.com",
        "mgid.com", "revcontent.com", "adsterra.com", "exoclick.com", "juicyads.com", "trafficjunky.net",
        "popads.net", "popcash.net", "propellerads.com", "onclickads.net", "adcash.com", "clickadu.com",
        "hilltopads.net", "richpartners.com", "ad-maven.com", "admaven.com", "histats.com",
        "quantserve.com", "chartbeat.net", "hotjar.com", "mixpanel.com", "adskeeper.com",
        "imasdk.googleapis.com", "innovid.com", "springserve.com", "spotxchange.com", "tremorhub.com",
        "freewheel.tv", "fwmrm.net", "serving-sys.com", "adition.com", "videoamp.com",
    ]

    /// Ad endpoints on the site's own domain (so they are not "third-party").
    static let blockedFirstParty = [
        "dmxleo\\.dailymotion\\.com", "youtube\\.com/pagead/", "youtube\\.com/api/stats/ads",
        "youtube\\.com/ptracking", "youtube\\.com/api/stats/atr",
    ]

    /// Elements that are almost always ad slots.
    static let hiddenSelectors = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^='google_ads']", "[id*='div-gpt-ad']",
        ".ad-banner", ".ad-container", ".ad-slot", ".ad-wrapper", ".advert", ".advertisement",
        "iframe[src*='doubleclick.net']", "iframe[src*='googlesyndication.com']",
        // YouTube feed and sidebar ads (video-player ads are left alone so playback is not affected).
        "ytd-ad-slot-renderer", "ytd-display-ad-renderer", "ytd-promoted-sparkles-web-renderer",
        "ytd-in-feed-ad-layout-renderer", "ytd-banner-promo-renderer", "#masthead-ad", "#player-ads",
        ".ytp-ad-overlay-container", "ytd-companion-slot-renderer", "ytd-player-legacy-desktop-watch-ads-renderer",
    ]

    /// Runs before the page's own scripts. Strips ad data from YouTube's player responses (so no ad is
    /// ever scheduled) and skips any ad that still starts. Same idea as uBlock Origin's json-prune.
    static let youTubeScript = #"""
    (() => {
      if (!/(^|\.)(youtube\.com|youtube-nocookie\.com)$/.test(location.hostname)) return;
      if (window.__ydlAdPrune) return;
      window.__ydlAdPrune = true;
      const KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];
      const prune = (o) => {
        if (!o || typeof o !== 'object') return o;
        for (const k of KEYS) { if (k in o) { try { delete o[k]; } catch (e) {} } }
        if (o.playerResponse) prune(o.playerResponse);
        return o;
      };
      const hasAds = (o) => o && typeof o === 'object' &&
        (('adPlacements' in o) || ('playerAds' in o) || ('adSlots' in o) || (o.playerResponse && typeof o.playerResponse === 'object'));

      const origParse = JSON.parse;
      JSON.parse = function (text, reviver) {
        const v = origParse.call(this, text, reviver);
        try { if (hasAds(v)) prune(v); } catch (e) {}
        return v;
      };

      const origJson = Response.prototype.json;
      Response.prototype.json = function () {
        return origJson.call(this).then((v) => { try { if (hasAds(v)) prune(v); } catch (e) {} return v; });
      };

      let initial;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true,
          get() { return initial; },
          set(v) { initial = prune(v); },
        });
      } catch (e) {}

      setInterval(() => {
        const player = document.querySelector('.html5-video-player.ad-showing');
        if (!player) return;
        const video = player.querySelector('video');
        if (video && isFinite(video.duration) && video.duration > 0) { video.currentTime = video.duration; }
        const skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
        if (skip) skip.click();
      }, 250);
    })();
    """#

    /// Every blocking rule that does not name a resource type also matched the page's own address, so a site could
    /// refuse to open. Limit those rules to what a page loads (scripts, images, frames, pop-ups…), never the page
    /// itself. Ads stay blocked; the site still opens. Rules that hide elements are left alone.
    static func sparingPages(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              var rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return json }
        let subresources = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping", "fetch"]
        for i in rules.indices {
            guard (rules[i]["action"] as? [String: Any])?["type"] as? String == "block",
                  var trigger = rules[i]["trigger"] as? [String: Any] else { continue }
            var types = trigger["resource-type"] as? [String] ?? subresources
            types.removeAll { $0 == "document" }
            if types.isEmpty { continue }
            trigger["resource-type"] = types
            rules[i]["trigger"] = trigger
        }
        guard let out = try? JSONSerialization.data(withJSONObject: rules) else { return json }
        return String(decoding: out, as: UTF8.self)
    }

    static func rulesJSON() -> String {
        var rules: [[String: Any]] = blockedHosts.map { host in
            ["trigger": ["url-filter": host.replacingOccurrences(of: ".", with: "\\."),
                         "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        rules += blockedFirstParty.map { pattern in
            ["trigger": ["url-filter": pattern], "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"],
                      "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")]])
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return sparingPages(String(decoding: data, as: UTF8.self))
    }
}

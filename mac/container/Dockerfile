# iKVM-KeyPasta: IPMIView's KVM console in an amd64 Linux container, viewed in a browser.
#
# Why: the viewer loads x86_64-only native libraries. On macOS that needs an Intel JVM under
# Rosetta 2, which Apple removes in macOS 28. An amd64 container keeps it working — natively on
# Intel Macs and Linux, through the container runtime's amd64 emulation on Apple Silicon.
#
# Everything is Linux here, so IPMIView's own StunnelFacotry works (no macOS stand-in class) and
# the bundled BMCSecurity/linux/stunnel64 handles the tunnel.
FROM eclipse-temurin:8-jdk-jammy

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        tigervnc-standalone-server tigervnc-common websockify openbox tint2 xsettingsd curl \
        x11-xserver-utils x11-utils \
        libxext6 libxrender1 libxtst6 libxi6 libxft2 libfreetype6 fontconfig fonts-dejavu-core \
        libssl3 stunnel4 \
        icedtea-netx \
        ca-certificates tzdata procps \
    && rm -rf /var/lib/apt/lists/*

# noVNC 1.3.0 (Ubuntu 24.04's package, self-contained) instead of 22.04's 1.0.0: its clipboard
# carries any text (UTF-8, TigerVNC's extended clipboard), 1.0.0's only Latin-1; the paste hotkey
# (keypasta.js) hands the Mac's clipboard over with it.
RUN curl -fsSL -o /tmp/novnc.deb http://archive.ubuntu.com/ubuntu/pool/universe/n/novnc/novnc_1.3.0-2_all.deb \
    && dpkg-deb -x /tmp/novnc.deb /tmp/novnc && rm -rf /usr/share/novnc \
    && mv /tmp/novnc/usr/share/novnc /usr/share/novnc && rm -rf /tmp/novnc /tmp/novnc.deb
# The Mac's Option and Command as they are: noVNC swaps them on a Mac (Command: Alt, Option: AltGr),
# which made Option useless (no Alt, no paste hotkey). Now Command is the Windows key and Option
# Alt, as natively; the agent swaps them if asked (KeyPasta dialog). Fails the build if not found.
RUN perl -0pi -e 's/if \(browser\.isMac\(\) \|\| browser\.isIOS\(\)\) \{(\s*)switch \(keysym\)/if (false) {$1switch (keysym)/' \
        /usr/share/novnc/core/input/keyboard.js \
    && grep -q 'if (false) {' /usr/share/novnc/core/input/keyboard.js
# The paste hotkey with the Mac's clipboard (see keypasta.js), in every noVNC page.
COPY keypasta.js /usr/share/novnc/keypasta.js
RUN sed -i 's#</head>#    <script type="module" src="keypasta.js"></script>\n</head>#' /usr/share/novnc/vnc.html \
    && grep -q 'keypasta.js' /usr/share/novnc/vnc.html
# noVNC's landing page -> the viewer page, so http://localhost:PORT opens straight into it.
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html
# Served from /novnc/ (keypasta-web/novnc), not / as before: a browser that kept the earlier noVNC's
# files under the old addresses doesn't mix them with these. The root's vnc.html and index.html
# lead there (bookmarks). keypasta-websockify: the pages with "Cache-Control: no-cache" from now on.
COPY keypasta-websockify /usr/local/bin/keypasta-websockify
# bmc-check HOST: whether a BMC answers from here as IPMIView needs it (UDP 623, TCP ports)
COPY bmc-check /usr/local/bin/bmc-check
RUN chmod +x /usr/local/bin/keypasta-websockify /usr/local/bin/bmc-check && mkdir -p /usr/share/keypasta-web \
    && ln -s /usr/share/novnc /usr/share/keypasta-web/novnc \
    && printf '%s\n' '<!DOCTYPE html><meta charset="utf-8"><title>IPMIView</title>' \
        '<script>location.replace("novnc/vnc.html" + location.search + location.hash);</script>' \
        > /usr/share/keypasta-web/index.html \
    && cp /usr/share/keypasta-web/index.html /usr/share/keypasta-web/vnc.html
# Browser tab title: the desktop name alone ("IPMIView", set by entrypoint.sh), not "<name> - noVNC"
RUN sed -i -e 's/const PAGE_TITLE = "noVNC"/const PAGE_TITLE = "IPMIView"/' \
           -e 's/ + " - " + PAGE_TITLE//' -e 's/ + " - noVNC"//' /usr/share/novnc/app/ui.js \
    && sed -i 's#<title>noVNC</title>#<title>IPMIView</title>#' /usr/share/novnc/vnc.html

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# IPMIView dir, agent jar, the vMedia and screencap folders are bind-mounted at run time (see run.sh).
VOLUME ["/ipmiview", "/agent"]
EXPOSE 6080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

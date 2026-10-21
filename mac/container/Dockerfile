# iKVM-KeyPasta: IPMIView's KVM console in an amd64 Linux container, viewed in a browser.
#
# Why: the viewer loads x86_64-only native libraries. On macOS that needs an Intel JVM under
# Rosetta 2, which Apple removes in macOS 28. An amd64 container keeps it working — natively on
# Intel Macs and Linux, through the container runtime's amd64 emulation on Apple Silicon.
#
# Everything is Linux here, so IPMIView's own StunnelFacotry works (no macOS stand-in class) and
# the bundled BMCSecurity/linux/stunnel64 handles the tunnel.
#
# Ubuntu 26.04 (standard support to 2031) with Ubuntu's own Java 11 runtime (a JRE: nothing is
# built here). Java 11 is the image's java (PATH, update-alternatives, JAVA_HOME): IPMIView runs on
# it, its viewers on IPMIView's bundled JRE if it has one, else on it too, and IcedTea-Web
# (javaws, itweb-settings: JAVA_HOME is their "custom JRE") and the .jnlp viewer in it. Not Java 8:
# 26.04's IcedTea-Web is built against a newer Java and calls Java 9's
# URLConnection.setDefaultUseCaches(String, boolean) (NoSuchMethodError on 8). Not newer than 11
# for the viewer: its .jnlp asks for options Java 17 refuses (see the Windows launcher). Ubuntu's
# IcedTea-Web package pulls in the default Java (25), unused: IcedTea-Web needs the security
# manager, gone since Java 24.
FROM ubuntu:26.04
# KeyPasta's images, so run.sh removes only their old, unnamed builds (docker image prune --filter)
LABEL ikvm-keypasta=console

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-11-jre \
        tigervnc-standalone-server tigervnc-common tigervnc-tools websockify openbox tint2 xsettingsd curl \
        x11-xserver-utils x11-utils x11-xkb-utils \
        libxext6 libxrender1 libxtst6 libxi6 libxft2 libfreetype6 fontconfig fonts-dejavu-core \
        libssl3t64 stunnel4 \
        icedtea-netx \
        python3 ca-certificates tzdata procps \
    && update-alternatives --set java "$JAVA_HOME/bin/java" \
    && java -version 2>&1 | grep -q '"11\.' \
    && perl -pi -e 's/^fullversion=`\$\{JAVA\} -version 2>&1`/fullversion=`env -u JAVA_TOOL_OPTIONS \$\{JAVA\} -version 2>&1`/' \
        /usr/share/icedtea-web/bin/*.sh \
    && grep -q 'env -u JAVA_TOOL_OPTIONS' /usr/share/icedtea-web/bin/javaws.sh \
    && cd /tmp && apt-get download novnc && mv novnc_*.deb /tmp/novnc.deb \
    && rm -rf /var/lib/apt/lists/*
# noVNC 1.6.0 (26.04's package, downloaded above): only its files, unpacked, not installed (the
# package pulls in Node.js, which the pages don't need). Its clipboard carries any text (UTF-8,
# TigerVNC's extended clipboard); the paste hotkey (keypasta.js) hands the Mac's clipboard over
# with it. unpack-deb, not dpkg-deb -x: that failed under QEMU's emulation (see unpack-deb).
COPY unpack-deb /usr/local/bin/unpack-deb
RUN python3 /usr/local/bin/unpack-deb /tmp/novnc.deb usr/share/novnc /usr/share/novnc \
    && rm /tmp/novnc.deb
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
# noVNC's landing page -> the viewer page, so http://localhost:PORT/ opens straight into it:
# connecting at once (mandatory) and the desktop following the window's size (default), not by
# the address (?autoconnect=1&resize=remote).
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && printf '{"autoconnect": true}\n' > /usr/share/novnc/mandatory.json \
    && printf '{"resize": "remote"}\n' > /usr/share/novnc/defaults.json
# keypasta-websockify: websockify serving the pages with "Cache-Control: no-cache", so a browser
# never mixes cached files of an older noVNC with a newer one's.
COPY keypasta-websockify /usr/local/bin/keypasta-websockify
# bmc-check HOST: whether a BMC answers from here as IPMIView needs it (UDP 623, TCP ports)
COPY bmc-check /usr/local/bin/bmc-check
# keypasta-vncauth: the VNC port for apps, taking any password (macOS's Screen Sharing wants one)
COPY keypasta-vncauth /usr/local/bin/keypasta-vncauth
# keypasta-jnlp-jars: a .jnlp's jars from the BMC, Pack200 ones unpacked (Java 11's unpack200)
COPY keypasta-jnlp-jars /usr/local/bin/keypasta-jnlp-jars
RUN chmod +x /usr/local/bin/keypasta-websockify /usr/local/bin/bmc-check /usr/local/bin/keypasta-vncauth \
        /usr/local/bin/keypasta-jnlp-jars \
    && command -v tigervncpasswd \
    && test -x "$JAVA_HOME/bin/unpack200"   # tigervnc-tools: a password's file; the .jnlp's jars
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

{ pkgs }: {
  deps = [
    pkgs.chromium
    pkgs.xorg.xvfb
    pkgs.x11vnc
    pkgs.fluxbox
    pkgs.python3
    pkgs.nodejs
  ];
}

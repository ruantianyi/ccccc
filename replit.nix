{ pkgs }: {
  deps = [
    pkgs.chromium
    pkgs.xorg.xorgserver
    pkgs.x11vnc
    pkgs.fluxbox
    pkgs.python3
    pkgs.nodejs
  ];
}

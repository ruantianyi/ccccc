{ pkgs }: {
  deps = [
    pkgs.chromium
    pkgs.xorg.xorgserver
    pkgs.x11vnc
    pkgs.fluxbox pkgs.xclip
    pkgs.xclip
    pkgs.python3
    pkgs.nodejs
  ];
}

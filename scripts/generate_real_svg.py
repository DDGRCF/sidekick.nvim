import re
import html

def make_real_terminal_svg():
    with open("assets/real_nes_preview.html", "r", encoding="utf-8") as f:
        html_content = f.read()

    # Extract CSS classes and pre tag
    pre_match = re.search(r"<pre>(.*?)</pre>", html_content, re.DOTALL)
    pre_content = pre_match.group(1) if pre_match else ""

    lines = pre_content.strip().split("\n")
    
    # Generate SVG tspan lines
    svg_lines = []
    y = 65
    line_num = 1
    
    for line in lines:
        # Convert span classes to colors
        # Habamax colors:
        # Statement: #af87af (purple)
        # Identifier: #87afaf (cyan)
        # String: #5faf5f (green)
        # Special: #5f8787 (teal)
        # Constant: #d75f87 (magenta)
        # DiffChange: #5f87af (blue)
        # DiffText: #af87af / #e06c75 (highlighted diff)
        # DiffDelete: #af5f5f (red)

        clean = line
        clean = re.sub(r'<span class="Statement">(.*?)</span>', r'<tspan fill="#c678dd">\1</tspan>', clean)
        clean = re.sub(r'<span class="Identifier">(.*?)</span>', r'<tspan fill="#61afef">\1</tspan>', clean)
        clean = re.sub(r'<span class="String">(.*?)</span>', r'<tspan fill="#98c379">\1</tspan>', clean)
        clean = re.sub(r'<span class="Special">(.*?)</span>', r'<tspan fill="#56b6c2">\1</tspan>', clean)
        clean = re.sub(r'<span class="Constant">(.*?)</span>', r'<tspan fill="#d19a66">\1</tspan>', clean)
        clean = re.sub(r'<span class="DiffChange">(.*?)</span>', r'<tspan fill="#61afef" font-weight="bold">\1</tspan>', clean)
        clean = re.sub(r'<span class="DiffText">(.*?)</span>', r'<tspan fill="#e5c07b" font-weight="bold" text-decoration="underline">\1</tspan>', clean)
        clean = re.sub(r'<span class="DiffDelete">(.*?)</span>', r'<tspan fill="#e06c75">\1</tspan>', clean)
        # Handle nested span leftovers
        clean = re.sub(r'<span[^>]*>', '', clean)
        clean = clean.replace('</span>', '')

        bg_rect = ""
        if "e5c07b" in clean or "e06c75" in clean:
            bg_rect = f'<rect x="24" y="{y - 14}" width="852" height="20" fill="#2d3139" opacity="0.85" rx="3"/>'

        svg_lines.append(f'{bg_rect}<text x="32" y="{y}" font-family="JetBrains Mono, Menlo, Consolas, monospace" font-size="13" fill="#abb2bf"><tspan fill="#5c6370" width="30">{line_num:2d} </tspan>{clean}</text>')
        y += 22
        line_num += 1

    rendered_lines = "\n    ".join(svg_lines)

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 520" width="100%" height="100%">
  <defs>
    <linearGradient id="termBg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#1e1e1e"/>
      <stop offset="100%" stop-color="#141414"/>
    </linearGradient>
    <filter id="winShadow" x="-2%" y="-2%" width="104%" height="106%">
      <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.6"/>
    </filter>
  </defs>

  <!-- Neovim Window Frame -->
  <rect width="900" height="520" rx="10" fill="url(#termBg)" stroke="#333842" stroke-width="1.5" filter="url(#winShadow)"/>

  <!-- Native Title / Winbar -->
  <rect x="0" y="0" width="900" height="38" rx="10" fill="#21252b" stroke="#333842" stroke-width="0.8"/>
  <circle cx="20" cy="19" r="5.5" fill="#e06c75"/>
  <circle cx="36" cy="19" r="5.5" fill="#e5c07b"/>
  <circle cx="52" cy="19" r="5.5" fill="#98c379"/>
  <text x="75" y="23" font-family="JetBrains Mono, monospace" font-size="12" font-weight="600" fill="#9da5b4">NVIM v0.11.2 — [NES current] ↔ [NES suggested] (Sidekick Interactive Diff)</text>
  <rect x="765" y="8" width="120" height="22" rx="4" fill="#2c313a"/>
  <text x="778" y="23" font-family="JetBrains Mono, monospace" font-size="11" fill="#61afef">2 hunks active</text>

  <!-- Real Rendered Code Body -->
  <g>
    {rendered_lines}
  </g>

  <!-- Real Sidekick Interactive Review Footer -->
  <rect x="0" y="476" width="900" height="44" rx="0" fill="#21252b" stroke="#333842" stroke-width="1"/>
  <rect x="0" y="500" width="900" height="20" rx="10" fill="#21252b"/>
  <text x="24" y="503" font-family="JetBrains Mono, monospace" font-size="12" fill="#d19a66">
    <tspan fill="#61afef" font-weight="bold">[a]</tspan><tspan fill="#abb2bf">ccept · </tspan>
    <tspan fill="#e06c75" font-weight="bold">[r]</tspan><tspan fill="#abb2bf">eject · </tspan>
    <tspan fill="#98c379" font-weight="bold">[A]</tspan><tspan fill="#abb2bf">ll · </tspan>
    <tspan fill="#c678dd" font-weight="bold">[]c]</tspan><tspan fill="#abb2bf">jump hunk · </tspan>
    <tspan fill="#56b6c2" font-weight="bold">[Tab]</tspan><tspan fill="#abb2bf">switch pane · </tspan>
    <tspan fill="#5c6370" font-weight="bold">[q]</tspan><tspan fill="#abb2bf">uit</tspan>
  </text>
</svg>"""

    with open("assets/real-nes-preview.svg", "w", encoding="utf-8") as f:
        f.write(svg)
    print("Generated assets/real-nes-preview.svg from real Neovim session")

make_real_terminal_svg()

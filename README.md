# wallnvim

## Para que serve?

O **wallnvim** é um seletor visual de papéis de parede (*wallpapers*) em janela flutuante para o [Neovim](https://neovim.io/).

Ele permite navegar entre as imagens do seu diretório de wallpapers e definir qualquer uma delas como papel de parede com um único `Enter`, sem sair do Neovim.

**Tem suporte a imagens e modo sem imagem.** Há **dois layouts** disponíveis: `grid` (com miniaturas) e `list`/`text` (apenas nomes). No modo `auto`, o plugin detecta automaticamente se seu terminal suporta imagens via [Kitty Graphics Protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) (compatível com Kitty, WezTerm, Ghostty, Konsole e `tmux`) e escolhe o melhor layout. Caso não haja suporte, usa o modo texto automaticamente.

**Principais funcionalidades:**
- **Dois layouts** - `grid` com miniaturas ou `list`/`text` com nomes
- **Suporte a imagens** - Renderização com Kitty Graphics Protocol quando disponível
- **Cache persistente** - Miniaturas e metadados salvos em SQLite via LuaJIT FFI para carregamento instantâneo
- **Geração automática** - Miniaturas 320x180 geradas automaticamente com `ffmpeg` apenas para imagens novas ou modificadas
- **Modo texto/fallback** - Funciona em qualquer terminal sem suporte gráfico
- **Integração com `feh`** - Define o wallpaper usando seu gerenciador de wallpapers configurável

## Como usar

### Requisitos

- [Neovim](https://neovim.io/) >= 0.10.0
- [feh](https://feh.finalrewind.org/) (ou outro utilitário configurável via `cmd`)
- [ffmpeg](https://ffmpeg.org/) (para gerar as miniaturas)
- [sqlite3](https://sqlite.org/) ou `libsqlite3` (para o cache persistente)

### Instalação

Basta adicionar o plugin. Exemplo com [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "DaFi-1/wallnvim",
  config = function()
    require("wallnvim").setup({
      keymap = "<space>l",        -- Atalho para abrir o seletor
      dir = "~/Pictures/wallpapers", -- Diretório com suas imagens
      layout = "auto",            -- "grid", "list", "text" ou "auto"
      cmd = "feh",                -- Comando para definir wallpaper
      cmd_args = { "--no-fehbg", "--bg-fill" },
      width = 110,               -- Largura da janela flutuante
      height = 32,               -- Altura da janela flutuante
      cell_width = 16,           -- Largura de cada célula na grade
      cell_height = 6,           -- Altura de cada célula na grade
      gap = 1,                   -- Espaçamento entre células
      border = "rounded",        -- Borda da janela
      preload = true,            -- Pré-carrega miniaturas ao iniciar
    })
  end,
}
```

Você pode modificar qualquer uma dessas opções conforme sua preferência. Não é obrigatório passar todas, o plugin já vem com valores padrão.

#### Com [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "DaFi-1/wallnvim",
  config = function()
    require("wallnvim").setup({
      keymap = "<space>l",
      dir = "~/Pictures/wallpapers",
    })
  end
}
```

#### Com [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'DaFi-1/wallnvim'

lua << EOF
require("wallnvim").setup({
  keymap = "<space>l",
  dir = "~/Pictures/wallpapers",
})
EOF
```

### Formatos de imagem suportados

`.jpg`, `.jpeg`, `.png`, `.webp`, `.bmp`, `.gif`

## Comandos do plugin

| Comando | Descrição |
| --- | --- |
| `:WallNvim` | Abre o seletor visual de wallpapers |
| `:WallToggle` | Alterna entre abrir e fechar o seletor |
| `:WallSet <caminho>` | Define um wallpaper diretamente, sem abrir a interface |

## Teclas de atalho

### Na janela do seletor

| Tecla | Ação |
| --- | --- |
| `h` / `←` | Navegar para a célula à esquerda |
| `l` / `→` | Navegar para a célula à direita |
| `k` / `↑` | Navegar para a célula acima |
| `j` / `↓` | Navegar para a célula abaixo |
| `<Tab>` | Alterna entre layout em grade (`grid`) e lista (`list`/`text`) |
| `<CR>` / `Enter` | Define a imagem selecionada como wallpaper |
| `q` / `<Esc>` / `<C-c>` | Fecha o seletor |

### Atalho global (opcional)

Se configurado com `keymap`, você pode abrir o seletor diretamente com o atalho definido (padrão desativado).

## Licença de Código Aberto

MIT License

Copyright (c) 2026 DaFi-1

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

"" Source your .vimrc
"source ~/.vimrc

nnoremap <SPACE> <Nop>
let mapleader=" "

" show relative line numbers except on your current line show absolute line number
set relativenumber
set number

" when pasting, the text you are highlighting does not replace the text in your register
vnoremap p pgvy

" make Y behave like D and C, yanking til end of line
map Y y$

" copy / paste to / from system clipboard with leader y / p
" map <leader>y \"+y
" map <leader>p \"+p
set clipboard=unnamedplus,unnamed,ideaput " integrate with system clipboard

" paste over rest of line with leader p
nnoremap <leader>p v$<Left>pgvy

" don't lose selection when indenting
vnoremap < <gv
vnoremap > >gv
vnoremap = =gv

noremap <leader>j J
noremap J <C-d>zz
noremap K <C-u>zz

noremap <leader>d "_d
noremap <leader>D "_d$

nnoremap <leader>o o<Esc>
nnoremap <leader>O O<Esc>

inoremap jj <Esc>

" Show a few lines of context around the cursor. Note that this makes the
" text scroll if you mouse-click near the start or end of the window.
set scrolloff=5 sidescrolloff=10

set ignorecase                    " ignore case in search patterns
set smartcase                     " no ignore case when pattern is uppercase
set incsearch                     " show search results while typing
set wrapscan                      " searches wrap around the end of the file

" Don't use Ex mode, use Q for formatting.
map Q gq

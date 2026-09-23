" Vimscript: a leading " is a comment, anywhere else a string.
set number
set tabstop=4 shiftwidth=4
let g:mapleader = ","
nnoremap <leader>w :w<CR>   " part of the mapping, so not a comment
echo "a string"

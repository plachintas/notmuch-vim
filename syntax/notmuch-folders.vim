" notmuch folders mode syntax file

if g:notmuch_folders_count_unreads == 0
    syntax region nmFoldersCount     start='^' end='\%10v'
    syntax region nmFoldersName      start='\%11v' end='  ('me=e-1
else
    syntax region nmFoldersCount     start='^' end='\%16v'
    syntax region nmFoldersName      start='\%17v' end='  ('me=e-1
endif
syntax match  nmFoldersSearch    /([^()]\+)$/

highlight link nmFoldersCount     Statement
highlight link nmFoldersName      Type
highlight link nmFoldersSearch    String

highlight CursorLine term=reverse cterm=reverse gui=reverse


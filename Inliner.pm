package Games::Rezrov::Inliner;

# inline a few of the most frequently used z-machine memory access
# calls.  Provides a speed improvement at the cost of more obfuscated
# and heinously non-OO code.  Oh well.

# only works for TRIVIAL code: will break if "arguments" for inlined
# routines contain parens (can't handle nesting)

1;

sub inline {
  my $ref = shift;
  
  my $rep = 'vec($Games::Rezrov::STORY_BYTES, $Games::Rezrov::PC++, 8)';
  $$ref =~ s/GET_BYTE\(\)/$rep/og;
  # replaces StoryFile::get_byte() -- z-machine memory access
  
  $rep = '(vec($Games::Rezrov::STORY_BYTES, $Games::Rezrov::PC++, 8) << 8) + vec($Games::Rezrov::STORY_BYTES, $Games::Rezrov::PC++, 8)';
  $$ref =~ s/GET_WORD\(\)/$rep/og;
  # replaces StoryFile::get_word() -- z-machine memory access

  $$ref =~ s/UNSIGNED_WORD\((.*?)\)/unpack\(\"S\", pack\(\"s\", $1\)\)/og;
  # cast a perl variable into a unsigned 16-bit word (short).
  # Necessary to ensure the sign bit is placed at 0x8000.
  # Replaces unsigned_word() subroutine.

#  $rep = 'unpack("s", pack("s", $1))';
#   if ($$ref =~ s/SIGNED_WORD\((.*?)\)/$rep/og) {
  $$ref =~ s/SIGNED_WORD\((.*?)\)/unpack\(\"s\", pack\(\"s\", $1\)\)/og;
  # cast a perl variable into a signed 16-bit word (short).
  # replaces signed_word() subroutine.


}

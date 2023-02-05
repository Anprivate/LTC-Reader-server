program tc_reader_server;

uses
  Forms,
  MainUnit in 'MainUnit.pas' {FormTCreader},
  UnitOneBuff in 'UnitOneBuff.pas',
  audio_card_capture in 'audio_card_capture.pas',
  DeckLinkAPI.Configuration in 'Include\DeckLinkAPI.Configuration.pas',
  DeckLinkAPI.DeckControl in 'Include\DeckLinkAPI.DeckControl.pas',
  DeckLinkAPI.Discovery in 'Include\DeckLinkAPI.Discovery.pas',
  DeckLinkAPI.Modes in 'Include\DeckLinkAPI.Modes.pas',
  DeckLinkAPI in 'Include\DeckLinkAPI.pas',
  DeckLinkAPI.Streaming in 'Include\DeckLinkAPI.Streaming.pas',
  DeckLinkAPI.Types in 'Include\DeckLinkAPI.Types.pas',
  tc_decoder in 'tc_decoder.pas',
  wasapi_capture in 'wasapi_capture.pas',
  decklink_capture in 'decklink_capture.pas',
  UnitOneDevice in 'UnitOneDevice.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormTCreader, FormTCreader);
  Application.Run;

end.

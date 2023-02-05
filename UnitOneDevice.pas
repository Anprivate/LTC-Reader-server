unit UnitOneDevice;

interface

uses
  DeckLinkAPI, DeckLinkAPI.Discovery, DeckLinkAPI.Modes, MMDeviceAPI;

type
  TOneDevice = class(TObject)
    Name: string;
    DevNo: integer;
    Channels: integer;
    dl_card: IDecklink;
    wasapi_device_id: string;
    isOldAudio: boolean;
    isDecklink: boolean;
    isWasapi: boolean;
    Constructor Create; overload;

  end;

implementation

{ TOneDevice }

constructor TOneDevice.Create;
begin
  inherited Create;

  isOldAudio := false;
  isDecklink := false;
  isWasapi := false;
end;

end.

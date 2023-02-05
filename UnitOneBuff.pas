unit UnitOneBuff;

interface

uses
  System.Generics.Collections;

type
  TData16 = array [0 .. 16383] of smallint;
  PData16 = ^TData16;

  TOne_frame = class(TObject)
  private
    l_samples: integer;
    l_data: PData16;
    l_time_stamp: Int64;
    l_frequency: integer;
  public
    property samples: integer read l_samples;
    property data: PData16 read l_data;
    property time_stamp: Int64 read l_time_stamp;
    property frequency: integer read l_frequency;
    //
    Constructor Create(in_samples: integer; tmp_ts: Int64;
      sample_frequency: integer = 48000); overload;
    Destructor Destroy; override;
  end;

  TTLframes_list = TThreadList<TOne_frame>;
  TLframes_list = TList<TOne_frame>;

implementation

{ TOne_frame }

constructor TOne_frame.Create(in_samples: integer; tmp_ts: Int64;
  sample_frequency: integer = 48000);
begin
  inherited Create;
  //
  l_samples := in_samples;
  l_time_stamp := tmp_ts;
  l_frequency := sample_frequency;

  try
    l_data := GetMemory(l_samples * 2);
  except
    l_data := nil;
  end;
end;

destructor TOne_frame.Destroy;
begin
  if Assigned(l_data) then
    FreeMemory(l_data);

  l_data := nil;

  inherited;
end;

end.

unit UnitOneText;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TOne_text = class(TObject)
  private
    l_string: string;
  public
    property text: string read l_string;
    Constructor Create(intext: string); overload;
    Destructor Destroy; override;
  end;

  TTLtext_list = TThreadList<TOne_text>;
  TLtext_list = TList<TOne_text>;

implementation

{ TOne_text }

constructor TOne_text.Create(intext: string);
begin
  inherited Create;
  //
  l_string := FormatDateTime('yyyy-mm-dd hh:nn:ss:zzz', Now()) + ' ' + intext;
end;

destructor TOne_text.Destroy;
begin

  inherited;
end;

end.

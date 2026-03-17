program Console;

{$APPTYPE CONSOLE}

uses
  Horse,
  Horse.ResponseCache,
  SysUtils;

begin
  THorse.Use(ResponseCache(30)); // cache por 30 segundos

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Sleep(3000); // simula processamento pesado
      Res.Send('pong gerado em ' + FormatDateTime('hh:nn:ss.zzz', Now));
      Writeln('pong gerado em ' + FormatDateTime('hh:nn:ss.zzz', Now));
    end);

  THorse.Listen(9001);
end.

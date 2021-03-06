function val = smaDAC(ic, msg)
% With ramp support and new trigger scheme. Odd channels are ramped.
% Improved error treatment compared to smcdecaDAC3.m
global smdata;

inst = smdata.inst(ic(1)).data.inst; 
val = dacread(inst,msg); 

% '%*7c%d'

function dacwrite(inst, str)
try
    query(inst, str);
catch
    fprintf('WARNING: error in DAC (%s) communication. Flushing buffer.\n',inst.Port);
    while inst.BytesAvailable > 0
        fprintf(fscanf(inst));
    end
end

function val = dacread(inst, str, format)
if nargin < 3
    format = '%s';
end

i = 1;
while i < 10
    try
        val = query(inst, str, '%s\n', format);
        i = 10;
    catch
        fprintf('WARNING: error in DAC (%s) communication. Flushing buffer and repeating.\n',inst.Port);
        while inst.BytesAvailable > 0
            fprintf(fscanf(inst))
        end

        i = i+1;
        if i == 10
            error('Failed 10 times reading from DAC')
        end
    end
end
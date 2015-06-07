function logentry(index, varargin)
% function logentry(index, varargin)
% write entry varargin to logfile, starting with date if changed and time.
% if the "index" is not given, it writes to the general file (index = 1)
% if you give more than 2 arguments, remaining args will be used as
% variables in string. 

global loginfo;

if isempty(loginfo) 
    return;
end

if ischar(index) 
    str = index;
    index = 1;
else
    str = varargin{1};
    varargin = varargin(2:end);
end

t = clock;

logfile = fopen(loginfo(index).logfile, 'a');

if isempty(loginfo(index).lastdate) || any(loginfo(index).lastdate ~= t(1:3)); 
    loginfo(index).lastdate = t(1:3);
    fprintf(logfile, '\n\n%02d/%02d/%02d\n---------\n', t(2:3), mod(t(1), 100)');    
end
logstr = sprintf(str, varargin{:});
fprintf(logfile, '\n%02d:%02d: %s\n', t(4:5), logstr);

fclose(logfile);
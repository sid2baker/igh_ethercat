alias EhterCAT.Master
alias EtherCAT.Master.Nif

for file <- Path.wildcard("examples/**/*.ex") do
  Code.require_file(file)
end

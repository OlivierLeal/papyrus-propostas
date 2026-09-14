# Troca temporariamente um método de CLASSE (`self.foo`/`Klass.new`) por uma implementação fake,
# restaurando a original no fim — mesma técnica de AiStubHelper (redefinir na classe, não usar
# Object#stub do minitest/mock, que este projeto não carrega). Usado pra travar
# Logistics::DestinationResolver/MapboxDirections nos testes sem chamar rede/PostGIS de verdade.
module ClassMethodStubHelper
  def stub_class_method(klass, method_name, implementation)
    original = klass.method(method_name)
    klass.define_singleton_method(method_name, &implementation)
    yield
  ensure
    klass.define_singleton_method(method_name, original)
  end
end

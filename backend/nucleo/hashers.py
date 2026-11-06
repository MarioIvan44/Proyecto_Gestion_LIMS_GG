"""
Hasher de contraseñas compatible con el backend Node (bcryptjs).

bcryptjs usa solo los primeros 72 bytes de la contraseña y no avisa; la librería
`bcrypt` de Python 5.x, en cambio, lanza un error si la contraseña es más larga.
Este hasher recorta igual que bcryptjs, para que una contraseña larga funcione igual
en los dos sistemas. El formato guardado es el de Django: `bcrypt$<hash>`.
"""

from django.contrib.auth.hashers import BCryptPasswordHasher

LIMITE_BCRYPT = 72


def _recortar(password):
    datos = password.encode("utf-8") if isinstance(password, str) else bytes(password)
    return datos[:LIMITE_BCRYPT]


class BcryptCompatibleNodeHasher(BCryptPasswordHasher):
    algorithm = "bcrypt"
    rounds = 10  # el mismo costo que usa el backend Node (bcrypt.genSalt(10))

    def encode(self, password, salt):
        bcrypt = self._load_library()
        password = _recortar(password)
        data = bcrypt.hashpw(password, salt)
        return "%s$%s" % (self.algorithm, data.decode("ascii"))

    def verify(self, password, encoded):
        bcrypt = self._load_library()
        algorithm, data = encoded.split("$", 1)
        assert algorithm == self.algorithm
        return bcrypt.checkpw(_recortar(password), data.encode("ascii"))
